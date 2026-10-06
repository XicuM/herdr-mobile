import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../models/session.dart';

/// One machine's `/ws/session` link, its last snapshot, and the pane last viewed on it.
class _Conn {
  WebSocketChannel? channel;
  Timer? retry;
  bool connected = false;
  SessionSnapshot? snapshot;
  String? selectedPaneId;

  /// The highest `completion_seq` seen per pane: a snapshot fetched over HTTP can land after a newer
  /// pushed one, and going back and forth must not alert twice.
  final completions = <String, int>{};
}

/// Every saved machine keeps its own connection, so several can be connected at once; each can be
/// disconnected on its own. The *active* machine ([machine]) is just the one on screen: [snapshot],
/// [selectedPaneId] and the bridge requests below are its.
class HerdrClientService extends ChangeNotifier {
  String _host = '127.0.0.1';
  int _port = 7788;
  double _fontSize = 14;
  List<String> _machines = [];
  Map<String, String> _names = {};

  /// Machines the user disconnected; every other saved machine stays connected.
  Set<String> _off = {};
  bool _alerts = false;

  /// Panes that never raise an alert, as `host:port/pane_id`.
  Set<String> _muted = {};
  bool _keyBar = false;
  bool _started = false;
  bool _disposed = false;
  final _conns = <String, _Conn>{};

  /// HerdrApp.kt: the ongoing status notification, alerts, and taps on them.
  static const _android = MethodChannel('herdr/android');

  HerdrClientService() {
    _android.setMethodCallHandler((call) async {
      if (call.method != 'open') return;
      final String m = call.arguments['machine'];
      if (m != machine && _machines.contains(m)) switchMachine(m);
      if (m == machine) selectPane(call.arguments['pane']);
    });
    _native('ready');
    // Back from sleep, a connect attempt made while the network was down may still be pending, or the
    // retry timer frozen; try again right away instead of waiting on either.
    AppLifecycleListener(onResume: () {
      for (final m in _machines) {
        if (!_off.contains(m) && !isConnected(m)) _close(m);
      }
      notifyListeners();
    });
  }

  /// Fails harmlessly off Android (e.g. in tests).
  void _native(String method, [Object? args]) => _android.invokeMethod(method, args).ignore();

  String get host => _host;
  int get port => _port;
  String get machine => '$_host:$_port';
  bool get connected => isConnected(machine);
  bool get isDisconnected => isOff(machine);
  SessionSnapshot? get snapshot => _conns[machine]?.snapshot;
  String? get selectedPaneId => _conns[machine]?.selectedPaneId;
  PaneModel? get selectedPane => snapshot?.panes.where((p) => p.id == selectedPaneId).firstOrNull;
  double get fontSize => _fontSize;

  bool isConnected(String m) => _conns[m]?.connected ?? false;

  /// Disconnected by the user (as opposed to connecting, or connected).
  bool isOff(String m) => _off.contains(m);
  SessionSnapshot? snapshotOf(String m) => _conns[m]?.snapshot;

  /// Saved bridges as `host:port`, one per machine running herdr-bridge.
  List<String> get machines => _machines;

  @visibleForTesting
  void setSnapshotForTesting(SessionSnapshot snap, [String? m]) => _apply(m ?? machine, snap);

  /// The name given to [machine] when it was added, or its address.
  String nameOf(String machine) => _names[machine] ?? machine;

  /// What [m]'s agents are doing, e.g. "1 waiting · 2 working".
  String summaryOf(String m) {
    final counts = <String, int>{};
    for (final p in snapshotOf(m)?.panes ?? <PaneModel>[]) {
      counts[p.agentStatus] = (counts[p.agentStatus] ?? 0) + 1;
    }
    final text = [
      for (final (status, label) in [('blocked', 'waiting'), ('working', 'working'), ('done', 'done')])
        if (counts[status] != null) '${counts[status]} $label',
    ].join(' · ');
    return text.isEmpty ? 'No agents running' : text;
  }

  /// Background alerts: a foreground service keeps the connections open, with an ongoing notification
  /// showing their state, and agents that need input or finish raise an alert.
  bool get alerts => _alerts;

  /// [ask] requests the notification permission and the battery-optimization exemption.
  void setAlerts(bool on, {bool ask = true}) {
    _alerts = on;
    if (on && ask) _native('askPermissions');
    SharedPreferences.getInstance().then((p) => p.setBool('background_alerts', on));
    notifyListeners();
  }

  bool isMuted(String paneId) => _muted.contains('$machine/$paneId');

  /// Silences, or unsilences, the alerts of [paneId] on the active machine.
  void setMuted(String paneId, bool on) {
    final key = '$machine/$paneId';
    _muted = on ? {..._muted, key} : ({..._muted}..remove(key));
    SharedPreferences.getInstance().then((p) => p.setStringList('muted_panes', _muted.toList()));
    notifyListeners();
  }

  /// [muted] as stored in prefs.
  void setMutedPanes(List<String> muted) => _muted = muted.toSet();

  /// Whether the bottom bar shows the control keys in place of the message box.
  bool get keyBar => _keyBar;

  void setKeyBar(bool on) {
    _keyBar = on;
    SharedPreferences.getInstance().then((p) => p.setBool('show_keys', on));
    notifyListeners();
  }

  /// Opens the connections, once the saved state is loaded.
  void start() {
    _started = true;
    notifyListeners();
  }

  /// Every state change passes here, so the connections and the ongoing notification always mirror it.
  @override
  void notifyListeners() {
    super.notifyListeners();
    _sync();
    final on = _machines.where((m) => !_off.contains(m)).toList();
    if (!_alerts || on.isEmpty) return _native('status');
    final up = on.where(isConnected).toList();
    if (up.isEmpty) return _native('status', {'title': 'Reconnecting…', 'text': 'Alerts resume once connected'});
    final title = up.length == 1 ? 'Connected to ${nameOf(up.first)}' : 'Connected to ${up.length} machines';
    final waiting = on.length - up.length;
    _native('status', {
      'title': waiting == 0 ? title : '$title · $waiting reconnecting',
      'text': up.length == 1 ? summaryOf(up.first) : [for (final m in up) '${nameOf(m)}: ${summaryOf(m)}'].join('\n'),
    });
  }

  /// Opens a connection for every saved machine that isn't off and doesn't have one (or a retry pending).
  void _sync() {
    if (!_started || _disposed) return;
    for (final m in _machines) {
      final c = _conns.putIfAbsent(m, _Conn.new);
      if (!_off.contains(m) && c.channel == null && c.retry == null) _open(m, c);
    }
  }

  void _open(String m, _Conn c) {
    try {
      // Pings notice a connection that died silently (e.g. the phone changed networks), so it reconnects.
      // Without a timeout, an attempt made while the network is down can hang and never retry.
      final channel = IOWebSocketChannel.connect(Uri.parse('ws://$m/ws/session'),
          pingInterval: const Duration(seconds: 20), connectTimeout: const Duration(seconds: 5));
      c.channel = channel;
      // Connection failures also reach the stream's onError, which retries.
      channel.ready.ignore();
      // A closed or replaced socket's late frames are ignored.
      channel.stream.listen(
        (message) {
          if (c.channel != channel) return;
          if (!c.connected) {
            c.connected = true;
            notifyListeners();
          }
          _handleMessage(m, message);
        },
        onError: (_) => _dropped(c, channel),
        onDone: () => _dropped(c, channel),
      );
    } catch (_) {
      _dropped(c, null);
    }
  }

  /// Retries in 3 s, unless [c] was closed or reopened meanwhile.
  void _dropped(_Conn c, WebSocketChannel? channel) {
    if (c.channel != channel || _disposed) return;
    c.channel = null;
    c.connected = false;
    c.retry = Timer(const Duration(seconds: 3), () {
      c.retry = null;
      _sync();
    });
    notifyListeners();
  }

  /// Closes [m]'s connection; [_sync] reopens it unless [m] is off.
  void _close(String m) {
    final c = _conns[m];
    if (c == null) return;
    c.retry?.cancel();
    c.retry = null;
    final channel = c.channel;
    c.channel = null;
    channel?.sink.close();
    c.connected = false;
  }

  /// Reports failed bridge requests; set by the screen that shows them.
  void Function(String message)? onError;

  static const double minFontSize = 6;
  static const double maxFontSize = 32;

  void setFontSize(double size) {
    final clamped = size.clamp(minFontSize, maxFontSize).toDouble();
    if (clamped == _fontSize) return;
    _fontSize = clamped;
    notifyListeners();
    SharedPreferences.getInstance().then((p) => p.setDouble('terminal_font_size', clamped));
  }

  void _setActive(String host, int port) {
    _host = host;
    _port = port;
    SharedPreferences.getInstance().then((p) => p
      ..setString('herdr_host', host)
      ..setInt('herdr_port', port));
  }

  /// Shows the machine at [host]:[port], remembering it in the machine list and, with [connect],
  /// connecting it if it was off.
  void configure({required String host, required int port, String? name, bool connect = true}) {
    _setActive(host, port);
    if (!_machines.contains(machine)) _machines = [..._machines, machine];
    if (name != null && name.isNotEmpty) _names = {..._names, machine: name};
    if (connect) _off = {..._off}..remove(machine);
    _saveMachines();
    notifyListeners();
  }

  /// [machines] are `host:port`; [names] are `host:port=name`; [off] are the disconnected ones, as
  /// stored in prefs.
  void setMachines(List<String> machines, List<String> names, [List<String> off = const []]) {
    _machines = machines;
    _names = {
      for (final n in names)
        if (n.contains('=')) n.substring(0, n.indexOf('=')): n.substring(n.indexOf('=') + 1)
    };
    _off = off.toSet();
    notifyListeners();
  }

  /// Forgets [m]; removing the active machine shows another.
  void removeMachine(String m) {
    _close(m);
    _conns.remove(m);
    _machines = _machines.where((x) => x != m).toList();
    _names = {..._names}..remove(m);
    _off = {..._off}..remove(m);
    _saveMachines();
    // The next one is shown as it was: one the user disconnected stays off.
    if (m == machine && _machines.isNotEmpty) return switchMachine(_machines.first, connect: false);
    if (m == machine) {
      SharedPreferences.getInstance().then((p) => p
        ..remove('herdr_host')
        ..remove('herdr_port'));
    }
    notifyListeners();
  }

  /// Renames [m] and/or moves it to [host]:[port], keeping its place in the list and its on/off state.
  void updateMachine(String m, {required String host, required int port, required String name}) {
    final next = '$host:$port';
    _machines = [
      for (final x in _machines)
        if (x == m) next else if (x != next) x
    ];
    _names = {..._names}..remove(m);
    if (name.isNotEmpty) _names[next] = name;
    if (next != m) {
      _close(m);
      _conns.remove(m);
      if (_off.remove(m)) _off.add(next);
      if (m == machine) _setActive(host, port);
    }
    _saveMachines();
    notifyListeners();
  }

  void _saveMachines() => SharedPreferences.getInstance().then((p) => p
    ..setStringList('herdr_machines', _machines)
    ..setStringList('herdr_machine_names', [for (final e in _names.entries) '${e.key}=${e.value}'])
    ..setStringList('herdr_machines_off', _off.toList()));

  /// Shows [machine] (`host:port` as stored in [machines]), with [connect] connecting it if it was off.
  /// The others stay as they are.
  void switchMachine(String machine, {bool connect = true}) {
    final i = machine.lastIndexOf(':');
    configure(host: machine.substring(0, i), port: int.parse(machine.substring(i + 1)), connect: connect);
  }

  void selectPane(String paneId) {
    _conns.putIfAbsent(machine, _Conn.new).selectedPaneId = paneId;
    _native('cancel', {'key': '$machine/$paneId'});
    notifyListeners();
  }

  /// Selects the tab's focused pane (or its first).
  void selectTab(String tabId) {
    final panes = snapshot?.panes.where((p) => p.tabId == tabId) ?? <PaneModel>[];
    final pane = panes.where((p) => p.focused).firstOrNull ?? panes.firstOrNull;
    if (pane != null) selectPane(pane.id);
  }

  /// Selects the workspace's active tab.
  void selectWorkspace(String workspaceId) {
    final ws = snapshot?.workspaces.where((w) => w.id == workspaceId).firstOrNull;
    final tab = ws?.activeTabId ?? snapshot?.tabs.where((t) => t.workspaceId == workspaceId).firstOrNull?.id;
    if (tab != null) selectTab(tab);
  }

  /// Disconnects [m] (the active machine by default) and keeps it off until [connect]ed.
  void disconnect([String? m]) {
    m ??= machine;
    _off = {..._off, m};
    _close(m);
    _saveMachines();
    notifyListeners();
  }

  void connect([String? m]) {
    _off = {..._off}..remove(m ?? machine);
    _saveMachines();
    notifyListeners();
  }

  void _handleMessage(String m, dynamic message) {
    try {
      final data = jsonDecode(message.toString());
      final type = data['type'];
      // The bridge pushes a snapshot whenever it changed. An older bridge also forwards raw events,
      // which are ignored: the snapshot that follows carries their change.
      if (type == 'snapshot') _apply(m, SessionSnapshot.fromJson(data['data']));
    } catch (e) {
      debugPrint('Error parsing session WS message: $e');
    }
  }

  void _apply(String m, SessionSnapshot snapshot) {
    final c = _conns.putIfAbsent(m, _Conn.new);
    final before = c.snapshot;
    c.snapshot = snapshot;
    if (!snapshot.panes.any((p) => p.id == c.selectedPaneId)) {
      c.selectedPaneId = _fallbackPane(m, c.selectedPaneId, before, snapshot);
    }
    // After a dropout [before] is the last snapshot seen, so what changed meanwhile still alerts.
    if (before != null && _alerts) _alertChanges(m, before, snapshot);
    // herdr reuses a closed pane's id, and the new pane mustn't come up muted.
    final gone = _muted.where((k) => k.startsWith('$m/') && !snapshot.panes.any((p) => '$m/${p.id}' == k));
    if (gone.isNotEmpty) {
      _muted = _muted.difference(gone.toSet());
      SharedPreferences.getInstance().then((p) => p.setStringList('muted_panes', _muted.toList()));
    }
    notifyListeners();
  }

  /// The pane to show once the selected one is gone (its shell exited, or its tab or workspace closed):
  /// another pane of its tab, else the tab before it (after it, if it was first), else the workspace
  /// before it (or after). When the last pane anywhere on the active machine is gone it opens a new
  /// workspace.
  String? _fallbackPane(String m, String? selected, SessionSnapshot? before, SessionSnapshot now) {
    final gone = before?.panes.where((p) => p.id == selected).firstOrNull;
    if (gone == null) return now.focusedPaneId ?? now.panes.firstOrNull?.id;
    if (now.panes.isEmpty) {
      if (m == machine) createWorkspace();
      return null;
    }
    List<String> around(List<String> ids, String id) {
      final i = ids.indexOf(id);
      return [...ids.sublist(0, i).reversed, ...ids.sublist(i + 1)];
    }

    String? paneOf(String? tabId) {
      final panes = now.panes.where((p) => p.tabId == tabId);
      return (panes.where((p) => p.focused).firstOrNull ?? panes.firstOrNull)?.id;
    }

    final tabs = [
      for (final t in before!.tabs)
        if (t.workspaceId == gone.workspaceId) t.id
    ];
    for (final tabId in [gone.tabId, ...around(tabs, gone.tabId)]) {
      final pane = paneOf(tabId);
      if (pane != null) return pane;
    }
    for (final wsId in around([for (final w in before.workspaces) w.id], gone.workspaceId)) {
      final ws = now.workspaces.where((w) => w.id == wsId).firstOrNull;
      final pane = paneOf(ws?.activeTabId) ?? paneOf(now.tabs.where((t) => t.workspaceId == wsId).firstOrNull?.id);
      if (pane != null) return pane;
    }
    return now.focusedPaneId ?? now.panes.first.id;
  }

  /// Alerts on agents that just started waiting for input or just completed work. Completion is read
  /// from `completion_seq`, which herdr bumps on every completion: `done` only lasts until the pane is
  /// viewed, so an agent whose pane is on screen goes straight from working to idle.
  void _alertChanges(String m, SessionSnapshot before, SessionSnapshot now) {
    final watching = m == machine && WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    final completions = _conns[m]!.completions;
    for (final pane in now.panes) {
      final was = before.panes.where((p) => p.id == pane.id).firstOrNull;
      final wasAgent = before.agents.where((a) => a.paneId == pane.id).firstOrNull;
      final agent = now.agents.where((a) => a.paneId == pane.id).firstOrNull;
      final seen = completions[pane.id] ?? wasAgent?.completionSeq ?? 0;
      final seq = agent?.completionSeq ?? 0;
      if (seq > seen) completions[pane.id] = seq;
      if (watching && pane.id == selectedPaneId || _muted.contains('$m/${pane.id}')) continue;
      final blocked = was != null && was.agentStatus != 'blocked' && pane.agentStatus == 'blocked';
      final finished = wasAgent != null && seq > seen;
      if (!blocked && !finished) continue;
      final task = pane.terminalTitle.isNotEmpty ? pane.terminalTitle : agent?.name ?? pane.id;
      final workspace = now.workspaces.where((w) => w.id == pane.workspaceId).firstOrNull;
      _native('alert', {
        'key': '$m/${pane.id}',
        'title': '${blocked ? 'Needs you' : 'Finished'}: $task',
        'text': [if (workspace != null) workspace.displayName, nameOf(m)].join(' · '),
        'machine': m,
        'pane': pane.id,
        'urgent': blocked,
      });
    }
  }

  Future<void> _fetchSnapshotHttp(String m) async {
    try {
      final res = await http.get(Uri.http(m, '/api/snapshot'));
      if (res.statusCode == 200 && _machines.contains(m) && !_off.contains(m)) {
        _apply(m, SessionSnapshot.fromJson(jsonDecode(res.body)));
      }
    } catch (_) {}
  }

  /// Sends one request to the active machine's bridge, then refreshes that machine's snapshot (also on
  /// failure, which may have changed something, or undoes [moveWorkspaces]'s local reorder). Failures go
  /// to [onError] as "Could not [what]". Returns the decoded response, or null on failure.
  Future<dynamic> _request(String what, String method, String path,
      {Map<String, dynamic>? body, Map<String, String>? query}) async {
    final m = machine;
    dynamic result;
    try {
      final req = http.Request(method, Uri.http(m, path, query));
      if (body != null) {
        req.headers['Content-Type'] = 'application/json';
        req.body = jsonEncode(body);
      }
      final res = await http.Response.fromStream(await req.send());
      if (res.statusCode != 200) throw res.body;
      result = res.body.isEmpty ? null : jsonDecode(res.body);
    } catch (e) {
      onError?.call('Could not $what: ${_parseError(e)}');
    }
    await _fetchSnapshotHttp(m);
    return result;
  }

  /// POSTs to a route that creates a tab or workspace, then shows its root pane, unless another
  /// machine was put on screen meanwhile.
  Future<void> _create(String what, String path, Map<String, dynamic> body) async {
    final m = machine;
    final res = await _request(what, 'POST', path, body: body);
    final paneId = res is Map ? (res['root_pane']?['pane_id']) : null;
    if (paneId is String && m == machine) selectPane(paneId);
  }

  String _parseError(dynamic e) {
    try {
      final data = jsonDecode(e.toString());
      if (data is Map && data['message'] != null) return data['message'].toString();
      if (data is Map && data['error'] != null) {
        if (data['error'] is Map && data['error']['message'] != null) {
          return data['error']['message'].toString();
        }
        return data['error'].toString();
      }
    } catch (_) {}
    return e.toString();
  }

  Future<void> createTab(String workspaceId) => _create('create tab', '/api/tab', {'workspace_id': workspaceId});

  Future<void> closeTab(String tabId) => _request('close tab', 'DELETE', '/api/tab/$tabId');

  Future<void> closePane(String paneId) => _request('close agent', 'DELETE', '/api/pane/$paneId');

  Future<void> renameTab(String tabId, String label) =>
      _request('rename tab', 'POST', '/api/tab/$tabId/rename', body: {'label': label});

  Future<void> createWorkspace() => _create('create workspace', '/api/workspace', {});

  Future<void> deleteWorkspace(String workspaceId, {bool removeWorktree = false, bool force = false}) {
    final query = {if (removeWorktree) 'remove_worktree': 'true', if (force) 'force': 'true'};
    return _request('delete workspace', 'DELETE', '/api/workspace/$workspaceId', query: query.isEmpty ? null : query);
  }

  Future<void> renameWorkspace(String workspaceId, String label) =>
      _request('rename workspace', 'POST', '/api/workspace/$workspaceId/rename', body: {'label': label});

  /// Moves [ids] (a workspace and its linked worktrees) before [beforeId], or to the end when null.
  /// Reorders the local snapshot first so the drawer doesn't jump back while the request runs.
  Future<void> moveWorkspaces(List<String> ids, String? beforeId) async {
    final list = snapshot?.workspaces;
    if (list != null) {
      final moved = list.where((w) => ids.contains(w.id)).toList();
      list.removeWhere((w) => ids.contains(w.id));
      final at = list.indexWhere((w) => w.id == beforeId);
      list.insertAll(at < 0 ? list.length : at, moved);
      notifyListeners();
    }
    await _request('move workspace', 'POST', '/api/workspace/move',
        body: {'workspace_ids': ids, 'before_workspace_id': beforeId});
  }

  Future<void> createWorktree(String workspaceId, String branch, {String? base, String? path, String? label}) =>
      _create('create worktree', '/api/worktree', {
        'workspace_id': workspaceId,
        'branch': branch,
        if (base != null && base.isNotEmpty) 'base': base,
        if (path != null && path.isNotEmpty) 'path': path,
        if (label != null && label.isNotEmpty) 'label': label,
      });

  Future<List<Map<String, dynamic>>> listWorktrees(String workspaceId) async {
    final res = await _request('list worktrees', 'GET', '/api/worktree', query: {'workspace_id': workspaceId});
    return ((res is Map ? res['worktrees'] : null) as List<dynamic>? ?? []).cast<Map<String, dynamic>>();
  }

  Future<void> openWorktree(String workspaceId, {String? branch, String? path}) =>
      _create('open worktree', '/api/worktree/open', {
        'workspace_id': workspaceId,
        if (branch != null) 'branch': branch,
        if (path != null) 'path': path,
      });

  @override
  void dispose() {
    _disposed = true;
    _conns.keys.toList().forEach(_close);
    super.dispose();
  }
}
