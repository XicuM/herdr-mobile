import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../models/session.dart';
import '../ui/widgets/agent_avatar.dart';

/// What the volume keys do on the terminal screen; [volume] leaves them to the system.
enum VolumeKeys { fontSize, arrows, volume }

/// One machine's `/ws/session` link, its last snapshot, and the pane last viewed on it.
class _Conn {
  WebSocketChannel? channel;
  Timer? retry;
  bool connected = false;
  SessionSnapshot? snapshot;
  String? selectedPaneId;

  /// Why the bridge has no snapshot (herdr not running, or the machine unreachable from it), until it has.
  String? error;

  /// The highest `completion_seq` seen per pane: a snapshot fetched over HTTP can land after a newer
  /// pushed one, and going back and forth must not alert twice.
  final completions = <String, int>{};

  /// Per pane, its agent's last `state_change_seq` (0 when herdr sends none), its status and when this
  /// app saw that change: herdr has no timestamps. Null for an agent already there in the first snapshot,
  /// whose last change the app never saw.
  final changes = <String, (int, String, DateTime?)>{};
}

/// Every saved machine keeps its own connection, so several can be connected at once; each can be
/// disconnected on its own. The *active* machine ([machine]) is just the one on screen: [snapshot],
/// [selectedPaneId] and the bridge requests below are its.
class HerdrClientService extends ChangeNotifier {
  String _machine = '127.0.0.1:7788';
  double _fontSize = 14;
  Color? _seed;
  Color? _systemSeed;
  Brightness? _brightness;
  List<String> _machines = [];
  Map<String, String> _names = {};

  /// Machines the user disconnected; every other saved machine stays connected.
  Set<String> _off = {};
  bool _alerts = false;
  bool _alertBlocked = true;
  bool _alertFinished = true;
  bool _alertSound = true;
  bool _alertDesktop = true;

  /// Panes that never raise an alert, as `machine/pane_id`.
  Set<String> _muted = {};
  bool _keyBar = false;
  VolumeKeys _volumeKeys = VolumeKeys.fontSize;
  bool _pinchZoom = true;
  bool _hideMessageTerminal = false;
  bool _started = false;
  bool _disposed = false;
  final _conns = <String, _Conn>{};

  /// HerdrApp.kt: the ongoing status notification, alerts, and taps on them.
  static const _android = MethodChannel('herdr/android');

  HerdrClientService() {
    _android.setMethodCallHandler((call) async {
      // The ongoing notification's Disconnect: every machine goes off, which also stops the service.
      if (call.method == 'disconnect') {
        _off = {..._machines};
        _machines.forEach(_close);
        _saveMachines();
        return notifyListeners();
      }
      if (call.method != 'open') return;
      final String m = call.arguments['machine'];
      if (m != machine && _machines.contains(m)) switchMachine(m);
      if (m == machine) selectPane(call.arguments['pane']);
    });
    _native('ready');
    _loadSystemSeed();
    // Back from sleep, a connect attempt made while the network was down may still be pending, or the
    // retry timer frozen; try again right away instead of waiting on either.
    AppLifecycleListener(onResume: () {
      _loadSystemSeed();
      for (final m in _machines) {
        if (!_off.contains(m) && !isConnected(m)) _close(m);
      }
      notifyListeners();
    });
  }

  /// Fails harmlessly off Android (e.g. in tests).
  void _native(String method, [Object? args]) => _android.invokeMethod(method, args).ignore();

  /// Reread on every resume, since the wallpaper may have changed.
  void _loadSystemSeed() => _android.invokeMethod<int>('systemColor').then((c) {
        final seed = c == null ? null : Color(c);
        if (seed == _systemSeed) return;
        _systemSeed = seed;
        notifyListeners();
      }).ignore();

  /// The machine on screen, as stored in [machines].
  String get machine => _machine;
  bool get connected => isConnected(machine);
  bool get isDisconnected => isOff(machine);

  /// None while the machine is off: its last one is kept, for alerts and the selected pane, but is stale.
  SessionSnapshot? get snapshot => isDisconnected ? null : _conns[machine]?.snapshot;
  String? get selectedPaneId => _conns[machine]?.selectedPaneId;
  PaneModel? get selectedPane => snapshot?.panes.where((p) => p.id == selectedPaneId).firstOrNull;
  double get fontSize => _fontSize;

  /// The app's accent colour, the seed of its Material colour scheme: the one picked in Settings, else
  /// Material You's (Android 12+), else sky.
  Color get seed => _seed ?? _systemSeed ?? const Color(0xFF38BDF8);

  /// The accent picked in Settings; null follows the system's.
  Color? get pickedSeed => _seed;

  /// Material You's accent, null before Android 12.
  Color? get systemSeed => _systemSeed;

  /// Light or dark; null follows the system.
  Brightness? get brightness => _brightness;

  bool isConnected(String m) => _conns[m]?.connected ?? false;

  /// Why [m]'s bridge can't show it, e.g. "ssh: Could not resolve hostname …"; null once it can.
  String? errorOf(String m) => isConnected(m) ? _conns[m]?.error : null;

  /// The bridge that reaches [m] over SSH (`host:port/m/<id>`, from its `/api/machines`), or null when
  /// [m] runs its own.
  static String? parentOf(String m) => m.contains('/') ? m.substring(0, m.indexOf('/')) : null;

  /// Disconnected by the user (as opposed to connecting, or connected).
  bool isOff(String m) => _off.contains(m);
  SessionSnapshot? snapshotOf(String m) => _conns[m]?.snapshot;

  /// Saved machines: bridges as `host:port`, each followed by the machines it reaches over SSH.
  List<String> get machines => _machines;

  @visibleForTesting
  void setSnapshotForTesting(SessionSnapshot snap, [String? m]) => _apply(m ?? machine, snap);

  @visibleForTesting
  void setConnectedForTesting(String m, bool connected) {
    (_conns[m] ??= _Conn()).connected = connected;
    notifyListeners();
  }

  /// The name given to [machine] when it was added, or its address.
  String nameOf(String machine) => _names[machine] ?? machine;

  /// What [m]'s agents are doing, e.g. "1 needs you · 2 working", in the alerts' words.
  String summaryOf(String m) {
    final counts = <String, int>{};
    for (final p in snapshotOf(m)?.panes ?? <PaneModel>[]) {
      counts[p.agentStatus] = (counts[p.agentStatus] ?? 0) + 1;
    }
    final text = [
      if (counts['blocked'] case final n?) '$n ${n == 1 ? 'needs' : 'need'} you',
      if (counts['working'] case final n?) '$n working',
      if (counts['done'] case final n?) '$n done',
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

  bool get alertBlocked => _alertBlocked;

  void setAlertBlocked(bool on) {
    _alertBlocked = on;
    SharedPreferences.getInstance().then((p) => p.setBool('alert_blocked', on));
    notifyListeners();
  }

  bool get alertFinished => _alertFinished;

  void setAlertFinished(bool on) {
    _alertFinished = on;
    SharedPreferences.getInstance().then((p) => p.setBool('alert_finished', on));
    notifyListeners();
  }

  bool get alertSound => _alertSound;

  void setAlertSound(bool on) {
    _alertSound = on;
    SharedPreferences.getInstance().then((p) => p.setBool('alert_sound', on));
    notifyListeners();
  }

  bool get alertDesktop => _alertDesktop;

  void setAlertDesktop(bool on) {
    _alertDesktop = on;
    SharedPreferences.getInstance().then((p) => p.setBool('alert_desktop', on));
    notifyListeners();
  }

  /// When the agent in [paneId] on [machine] (or the active machine) last changed status, if this app saw it.
  DateTime? changedAt(String paneId, [String? machine]) => _conns[machine ?? this.machine]?.changes[paneId]?.$3;

  bool isMuted(String paneId, [String? machine]) => _muted.contains('${machine ?? this.machine}/$paneId');

  /// Silences, or unsilences, the alerts of [paneId] on [machine] (or the active machine).
  void setMuted(String paneId, bool on, [String? machine]) {
    final key = '${machine ?? this.machine}/$paneId';
    _muted = on ? {..._muted, key} : ({..._muted}..remove(key));
    SharedPreferences.getInstance().then((p) => p.setStringList('muted_panes', _muted.toList()));
    notifyListeners();
  }

  /// Whether the bottom bar shows the control keys in place of the message box.
  bool get keyBar => _keyBar;

  void setKeyBar(bool on) {
    _keyBar = on;
    SharedPreferences.getInstance().then((p) => p.setBool('show_keys', on));
    notifyListeners();
  }

  VolumeKeys get volumeKeys => _volumeKeys;

  void setVolumeKeys(VolumeKeys v) {
    _volumeKeys = v;
    SharedPreferences.getInstance().then((p) => p.setString('volume_keys', v.name));
    notifyListeners();
  }

  bool get pinchZoom => _pinchZoom;

  void setPinchZoom(bool v) {
    _pinchZoom = v;
    SharedPreferences.getInstance().then((p) => p.setBool('pinch_zoom', v));
    notifyListeners();
  }

  bool get hideMessageTerminal => _hideMessageTerminal;

  void setHideMessageTerminal(bool v) {
    _hideMessageTerminal = v;
    SharedPreferences.getInstance().then((p) => p.setBool('hide_message_terminal', v));
    notifyListeners();
  }

  /// Reads the saved settings, without writing them back. The first launch turns alerts on and asks
  /// for the permissions they need. The machine on screen last time stays off if it was disconnected.
  void load(SharedPreferences p) {
    _fontSize = p.getDouble('terminal_font_size') ?? _fontSize;
    final seed = p.getInt('theme_seed');
    if (seed != null) _seed = Color(seed);
    _brightness = Brightness.values.asNameMap()[p.getString('theme_mode')];
    _keyBar = p.getBool('show_keys') ?? false;
    _volumeKeys = VolumeKeys.values.asNameMap()[p.getString('volume_keys')] ?? VolumeKeys.fontSize;
    _pinchZoom = p.getBool('pinch_zoom') ?? true;
    _hideMessageTerminal = p.getBool('hide_message_terminal') ?? false;
    _muted = (p.getStringList('muted_panes') ?? []).toSet();
    final alerts = p.getBool('background_alerts');
    alerts == null ? setAlerts(true) : _alerts = alerts;
    _alertBlocked = p.getBool('alert_blocked') ?? true;
    _alertFinished = p.getBool('alert_finished') ?? true;
    _alertSound = p.getBool('alert_sound') ?? true;
    _alertDesktop = p.getBool('alert_desktop') ?? true;
    setMachines(p.getStringList('herdr_machines') ?? [], p.getStringList('herdr_machine_names') ?? [],
        p.getStringList('herdr_machines_off') ?? []);
    final host = p.getString('herdr_host');
    if (host != null) {
      _machine = '$host:${p.getInt('herdr_port') ?? 7788}${p.getString('herdr_path') ?? ''}';
      if (!_machines.contains(machine)) _machines = [..._machines, machine];
    }
  }

  /// Opens the connections, once the saved state is loaded.
  void start() {
    _started = true;
    warmAgentIcons();
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
            if (parentOf(m) == null) _discover(m);
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

  /// Reports failed bridge requests; set by the app, which shows them as a SnackBar on any screen.
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

  void setSeed(Color? seed) {
    _seed = seed;
    notifyListeners();
    SharedPreferences.getInstance()
        .then((p) => seed == null ? p.remove('theme_seed') : p.setInt('theme_seed', seed.value));
  }

  void setBrightness(Brightness? brightness) {
    _brightness = brightness;
    notifyListeners();
    SharedPreferences.getInstance()
        .then((p) => brightness == null ? p.remove('theme_mode') : p.setString('theme_mode', brightness.name));
  }

  void _setActive(String m) {
    _machine = m;
    final slash = m.contains('/') ? m.indexOf('/') : m.length;
    final colon = m.lastIndexOf(':', slash);
    SharedPreferences.getInstance().then((p) => p
      ..setString('herdr_host', m.substring(0, colon))
      ..setInt('herdr_port', int.parse(m.substring(colon + 1, slash)))
      ..setString('herdr_path', m.substring(slash)));
  }

  /// Shows [m] (`host:port`, or a machine a bridge reaches), remembering it in the machine list and,
  /// with [connect], connecting it if it was off.
  void configure(String m, {String? name, bool connect = true}) {
    _setActive(m);
    if (!_machines.contains(machine)) _machines = [..._machines, machine];
    if (name != null && name.isNotEmpty) _names = {..._names, machine: name};
    if (connect) _off = {..._off}..remove(machine);
    _saveMachines();
    notifyListeners();
  }

  /// [machines] are as in [machines]; [names] are `machine=name`; [off] are the disconnected ones, as
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

  /// Forgets [m], and the machines it reaches; removing the active machine shows another.
  void removeMachine(String m) {
    _forget([m, ..._machines.where((x) => parentOf(x) == m)]);
    if (_machines.contains(machine)) return notifyListeners();
    if (_machines.isNotEmpty) return switchMachine(_machines.first);
    SharedPreferences.getInstance().then((p) => p
      ..remove('herdr_host')
      ..remove('herdr_port')
      ..remove('herdr_path'));
    notifyListeners();
  }

  void _forget(Iterable<String> gone) {
    for (final m in gone) {
      _close(m);
      _conns.remove(m);
    }
    _machines = _machines.where((x) => !gone.contains(x)).toList();
    _names = {..._names}..removeWhere((k, _) => gone.contains(k));
    _off = _off.difference(gone.toSet());
    _saveMachines();
  }

  /// Renames [m] and/or moves it to [to] (`host:port`), keeping its place in the list and its on/off
  /// state. The machines it reached are found again at the new address.
  void updateMachine(String m, {required String to, required String name}) {
    _machines = [
      for (final x in _machines)
        if (x == m) to else if (x != to) x
    ];
    _names = {..._names}..remove(m);
    if (name.isNotEmpty) _names[to] = name;
    if (to != m) {
      final (active, off) = (machine, _off.contains(m));
      _forget([m, ..._machines.where((x) => parentOf(x) == m)]);
      if (off) _off = {..._off, to};
      if (active == m || parentOf(active) == m) _setActive(to);
    }
    _saveMachines();
    notifyListeners();
  }

  /// Adds the machines [m]'s bridge reaches over SSH (those saved in its herdr) right after it, named as
  /// there, and forgets the ones it no longer does. A bridge without `/api/machines` reaches none.
  Future<void> _discover(String m) async {
    final List found;
    try {
      final res = await http.get(Uri.parse('http://$m/api/machines'));
      if (res.statusCode != 200) return;
      found = jsonDecode(res.body)['machines'];
    } catch (_) {
      return;
    }
    if (!_machines.contains(m)) return;
    final children = {for (final f in found) '$m/m/${f['id']}': f['label'] as String};
    _forget(_machines.where((x) => parentOf(x) == m && !children.containsKey(x)).toList());
    if (!_machines.contains(machine)) _setActive(m);
    final i = _machines.indexOf(m);
    final kept = _machines.where((x) => parentOf(x) == m).toList();
    final added = children.keys.where((x) => !_machines.contains(x)).toList();
    if (added.isEmpty) return notifyListeners();
    _machines = [..._machines.sublist(0, i + 1 + kept.length), ...added, ..._machines.sublist(i + 1 + kept.length)];
    _names = {..._names, for (final x in added) x: children[x]!};
    _saveMachines();
    notifyListeners();
  }

  void _saveMachines() => SharedPreferences.getInstance().then((p) => p
    ..setStringList('herdr_machines', _machines)
    ..setStringList('herdr_machine_names', [for (final e in _names.entries) '${e.key}=${e.value}'])
    ..setStringList('herdr_machines_off', _off.toList()));

  /// Shows [machine] (as stored in [machines]) as it is: one the user disconnected stays off. The others
  /// stay as they are.
  void switchMachine(String machine) => configure(machine, connect: false);

  void selectPane(String paneId) {
    _conns.putIfAbsent(machine, _Conn.new).selectedPaneId = paneId;
    _native('cancel', {'key': '$machine/$paneId'});
    notifyListeners();
  }

  /// Selects the tab's focused pane (or its first).
  void selectTab(String tabId) {
    final pane = snapshot?.paneOfTab(tabId);
    if (pane != null) selectPane(pane);
  }

  /// Selects the workspace's active tab.
  void selectWorkspace(String workspaceId) {
    final ws = snapshot?.workspaces.where((w) => w.id == workspaceId).firstOrNull;
    final tab = ws?.activeTabId ?? snapshot?.tabs.where((t) => t.workspaceId == workspaceId).firstOrNull?.id;
    if (tab != null) selectTab(tab);
  }

  /// [m] and, for a bridge, the machines it reaches.
  List<String> _withChildren(String m) => [m, ..._machines.where((x) => parentOf(x) == m)];

  /// Disconnects [m] (the active machine by default), and those it reaches, and keeps them off until
  /// [connect]ed.
  void disconnect([String? m]) {
    final all = _withChildren(m ?? machine);
    _off = {..._off, ...all};
    all.forEach(_close);
    _saveMachines();
    notifyListeners();
  }

  void connect([String? m]) {
    _off = _off.difference(_withChildren(m ?? machine).toSet());
    _saveMachines();
    notifyListeners();
  }

  void _handleMessage(String m, dynamic message) {
    try {
      final data = jsonDecode(message.toString());
      final type = data['type'];
      // The bridge pushes a snapshot whenever it changed, or why it has none. An older bridge also
      // forwards raw events, which are ignored: the snapshot that follows carries their change.
      if (type == 'snapshot') {
        _conns[m]?.error = null;
        _apply(m, SessionSnapshot.fromJson(data['data']));
      } else if (type == 'error') {
        _conns[m]?.error = data['error'].toString();
        notifyListeners();
      }
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
    // herdr reuses a closed pane's id: a new pane mustn't come up muted, nor inherit the old one's
    // completion count, which would hold back its "Finished" alerts.
    c.completions.removeWhere((id, _) => !snapshot.panes.any((p) => p.id == id));
    c.changes.removeWhere((id, _) => !snapshot.agents.any((a) => a.paneId == id));
    for (final a in snapshot.agents) {
      final was = c.changes[a.paneId];
      final seq = a.stateChangeSeq ?? 0;
      // A higher seq is a change; an older snapshot landing late (lower seq) isn't. Nor is `done` turning
      // `idle` when the pane is viewed: herdr leaves the seq as it was. Without seqs, a new status is.
      if (was == null || seq > was.$1 || seq == 0 && a.status != was.$2) {
        c.changes[a.paneId] = (seq, a.status, before == null ? null : DateTime.now());
      }
    }
    // A pane id has no slash, so the key's machine is all before its last one.
    final gone =
        _muted.where((k) => k.substring(0, k.lastIndexOf('/')) == m && !snapshot.panes.any((p) => '$m/${p.id}' == k));
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

    final tabs = [
      for (final t in before!.tabs)
        if (t.workspaceId == gone.workspaceId) t.id
    ];
    for (final tabId in [gone.tabId, ...around(tabs, gone.tabId)]) {
      final pane = now.paneOfTab(tabId);
      if (pane != null) return pane;
    }
    for (final wsId in around([for (final w in before.workspaces) w.id], gone.workspaceId)) {
      final ws = now.workspaces.where((w) => w.id == wsId).firstOrNull;
      final pane =
          now.paneOfTab(ws?.activeTabId) ?? now.paneOfTab(now.tabs.where((t) => t.workspaceId == wsId).firstOrNull?.id);
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
      if (blocked && !_alertBlocked) continue;
      if (finished && !_alertFinished) continue;
      final agentName = (agent?.name.isNotEmpty == true ? agent?.name : wasAgent?.name) ?? '';
      final task = pane.terminalTitle.isNotEmpty ? pane.terminalTitle : agentName.isNotEmpty ? agentName : pane.id;
      final workspace = now.workspaces.where((w) => w.id == pane.workspaceId).firstOrNull;
      final title = '${blocked ? 'Needs you' : 'Finished'}: $task';
      final text = [if (workspace != null) workspace.displayName, nameOf(m)].join(' · ');
      final iconName = agentName.isNotEmpty ? agentName : pane.terminalTitle;
      final iconBytes = agentIconBytes(iconName);
      _native('alert', {
        'key': '$m/${pane.id}',
        'title': title,
        'text': text,
        'machine': m,
        'pane': pane.id,
        'urgent': blocked,
        if (iconBytes != null) 'icon': iconBytes,
      });
      if (Platform.isLinux) {
        if (_alertDesktop) {
          final iconPath = agentIconPath(iconName) ?? 'utilities-terminal';
          Process.run('notify-send', [
            '-a',
            'Herdr',
            '-u',
            blocked ? 'critical' : 'normal',
            '-i',
            iconPath,
            title,
            text,
          ]).ignore();
        }
        if (_alertSound) {
          Process.run('canberra-gtk-play', ['-i', blocked ? 'dialog-warning' : 'message-new-instant']).then((res) {
            if (res.exitCode != 0) {
              Process.run('paplay', [
                '/usr/share/sounds/freedesktop/stereo/${blocked ? 'dialog-warning' : 'complete'}.oga',
              ]).ignore();
            }
          }).ignore();
        }
      }
    }
  }

  Future<void> _fetchSnapshotHttp(String m) async {
    try {
      final res = await http.get(Uri.parse('http://$m/api/snapshot'));
      if (res.statusCode == 200 && _machines.contains(m) && !_off.contains(m)) {
        _apply(m, SessionSnapshot.fromJson(jsonDecode(res.body)));
      }
    } catch (_) {}
  }

  /// Sends one request to [on]'s bridge (the active machine's by default), then refreshes that machine's snapshot (also on
  /// failure, which may have changed something, or undoes [moveTab]'s or [moveWorkspaces]'s local reorder). Failures go
  /// to [onError] as "Could not [what]". Returns the decoded response, or null on failure.
  Future<dynamic> _request(String what, String method, String path,
      {Map<String, dynamic>? body, Map<String, String>? query, String? on}) async {
    final m = on ?? machine;
    dynamic result;
    try {
      final req = http.Request(method, Uri.parse('http://$m$path').replace(queryParameters: query));
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

  /// Closes [paneId] on [m] (the active machine by default). herdr closes a tab with its last pane and a
  /// workspace with its last tab, so when this is the workspace's only pane it first opens a new tab
  /// there, leaving the workspace with a shell.
  Future<void> closePane(String paneId, [String? m]) async {
    final panes = snapshotOf(m ?? machine)?.panes ?? const [];
    final ws = panes.where((p) => p.id == paneId).firstOrNull?.workspaceId;
    if (ws != null && panes.where((p) => p.workspaceId == ws).length == 1) {
      await _request('create tab', 'POST', '/api/tab', body: {'workspace_id': ws}, on: m);
    }
    await _request('close agent', 'DELETE', '/api/pane/$paneId', on: m);
  }

  /// Moves a tab to [targetId]'s place in their workspace, reordering the local snapshot first so the strip
  /// doesn't jump back while the request runs.
  Future<void> moveTab(String tabId, String targetId) async {
    final all = snapshot?.tabs;
    final tab = all?.where((t) => t.id == tabId).firstOrNull;
    if (all == null || tab == null) return;
    final own = all.where((t) => t.workspaceId == tab.workspaceId).map((t) => t.id).toList();
    final from = own.indexOf(tabId), to = own.indexOf(targetId);
    if (to < 0 || to == from) return;
    all.remove(tab);
    all.insert(all.indexWhere((t) => t.id == targetId) + (from < to ? 1 : 0), tab);
    notifyListeners();
    // herdr's index is into the order before the move: the tab goes in front of the one there.
    await _request('move tab', 'POST', '/api/tab/move',
        body: {'tab_id': tabId, 'insert_index': from < to ? to + 1 : to});
  }

  Future<void> createWorkspace() => _create('create workspace', '/api/workspace', {});

  Future<void> deleteWorkspace(String workspaceId, {bool removeWorktree = false, bool force = false}) {
    final query = {if (removeWorktree) 'remove_worktree': 'true', if (force) 'force': 'true'};
    return _request('delete workspace', 'DELETE', '/api/workspace/$workspaceId', query: query.isEmpty ? null : query);
  }

  Future<void> renameWorkspace(String workspaceId, String label) =>
      _request('rename workspace', 'POST', '/api/workspace/$workspaceId/rename', body: {'label': label});

  /// Moves [ids] (a workspace and its linked worktrees) before [beforeId], or to the end when null.
  /// Reorders the local snapshot first so the list doesn't jump back while the request runs.
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
