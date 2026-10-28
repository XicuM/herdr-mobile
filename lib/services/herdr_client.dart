import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dynamic_color/dynamic_color.dart';
import 'package:material_color_utilities/material_color_utilities.dart';
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

/// What Enter does in the message box; [newline] inserts a new line (Ctrl+Enter sends),
/// [send] sends the message (Shift+Enter inserts a new line).
enum EnterBehavior { newline, send }

/// A file an agent sent the user (`herdr-bridge send`), offered on its pane until opened or dismissed.
class Delivery {
  Delivery(this.machine, Map<String, dynamic> json)
      : id = json['id'],
        name = json['name'],
        size = json['size'] ?? 0,
        mime = json['mime'] ?? 'application/octet-stream',
        title = json['title'],
        paneId = json['pane_id'];

  /// The bridge it came from, which serves it at `/api/deliveries/[id]`.
  final String machine;
  final String id, name, mime;
  final int size;
  final String? title;

  /// The sending agent's pane; null for an agent in another herdr session, offered on every pane.
  final String? paneId;

  /// How much has arrived (0–1) while downloading, else null.
  final progress = ValueNotifier<double?>(null);

  /// Where it was saved, so opening it again doesn't fetch it again.
  String? path;

  bool get isApk => mime == 'application/vnd.android.package-archive';

  String get sizeLabel => size >= 1 << 20
      ? '${(size / (1 << 20)).toStringAsFixed(1)} MB'
      : size >= 1 << 10
          ? '${(size / (1 << 10)).round()} KB'
          : '$size B';

  /// The title, then its size: what the alert and the card say under its name.
  String get detail => [if (title?.isNotEmpty == true) title!, sizeLabel].join(' · ');
}

/// One machine's `/ws/session` link, its last snapshot, and the pane last viewed on it.
class _Conn {
  WebSocketChannel? channel;

  /// [channel]'s socket, once connected, whose ping interval follows the app on and off screen.
  WebSocket? socket;
  Timer? retry;

  /// Failed attempts in a row, which space the retries out.
  int fails = 0;
  bool connected = false;

  /// What herdr last sent, and what's shown of it: the same, less anything closed but still undoable.
  SessionSnapshot? raw;
  SessionSnapshot? snapshot;
  String? selectedPaneId;

  /// Why the bridge has no snapshot (herdr not running, or the machine unreachable from it), until it has.
  String? error;

  /// Why the last attempt to connect failed, in words the user can act on, until one succeeds.
  String? failure;

  /// The highest `completion_seq` seen per pane: a snapshot fetched over HTTP can land after a newer
  /// pushed one, and going back and forth must not alert twice.
  final completions = <String, int>{};

  /// Per pane, its agent's last `state_change_seq` (0 when herdr sends none), its status and when this
  /// app saw that change: herdr has no timestamps. Null for an agent already there in the first snapshot,
  /// whose last change the app never saw, unless it is still the one saved before ([HerdrClientService._saved]).
  final changes = <String, (int, String, DateTime?)>{};
}

/// Every saved machine keeps its own connection, so several can be connected at once; each can be
/// disconnected on its own. The *active* machine ([machine]) is just the one on screen: [snapshot],
/// [selectedPaneId] and the bridge requests below are its.
class HerdrClientService extends ChangeNotifier {
  String _machine = '127.0.0.1:7788';
  double _fontSize = defaultFontSize;
  Color? _seed;
  Color? _systemSeed;
  CorePalette? _systemPalette;
  Brightness? _brightness;
  List<String> _machines = [];
  Map<String, String> _names = {};

  /// The SSH target of each machine a bridge reaches, as its herdr has it.
  Map<String, String> _targets = {};

  /// Each bridge's token (`herdr-bridge --print-token` there), sent with every request to it and to the
  /// machines it reaches.
  Map<String, String> _tokens = {};

  /// Machines the user disconnected; every other saved machine stays connected.
  Set<String> _off = {};
  bool _alerts = false;
  bool _alertBlocked = true;
  bool _alertFinished = true;
  bool _alertSound = true;
  bool _alertDesktop = true;

  /// Panes that never raise an alert, as `machine/pane_id`.
  Set<String> _muted = {};

  /// The [_Conn.changes] that have a time, as `machine/pane_id`, kept across restarts (pref `agent_changes`).
  /// A machine's first snapshot takes a time back only while the agent's seq (without seqs, its status) is
  /// still the saved one: otherwise it changed while the app wasn't looking, or herdr reused the pane's id.
  Map<String, (int, String, DateTime)> _saved = {};
  bool _keyBar = false;
  VolumeKeys _volumeKeys = VolumeKeys.fontSize;
  bool _pinchZoom = true;
  bool _hideMessageTerminal = false;
  EnterBehavior _enterBehavior = EnterBehavior.newline;
  bool _started = false;
  bool _disposed = false;
  final _conns = <String, _Conn>{};

  /// Files agents sent, oldest first, across machines ([deliveriesOf]).
  final _deliveries = <Delivery>[];

  /// HerdrApp.kt: the ongoing status notification, alerts, and taps on them.
  static const _android = MethodChannel('herdr/android');

  /// Called when an agent alert notification is tapped to reveal its terminal.
  void Function()? onOpenTerminal;
  bool openTerminalRequested = false;

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
      final String? m = call.arguments['machine'];
      final String? pane = call.arguments['pane'];
      if (m != null && m != machine && _machines.contains(m)) switchMachine(m);
      if (pane != null && pane.isNotEmpty) {
        if (m == machine || m == null) selectPane(pane);
        if (onOpenTerminal != null) {
          onOpenTerminal!();
        } else {
          openTerminalRequested = true;
        }
      }
      // A delivery's alert's Install/Open button.
      final delivery = _deliveries.where((d) => d.id == call.arguments['delivery']).firstOrNull;
      if (delivery != null) openDelivery(delivery);
    });
    _native('ready');
    _loadSystemSeed();
    _android.invokeMethod<int>('sdk').then((v) => _sdk = v).ignore();
    // Back from sleep, a connect attempt made while the network was down may still be pending, or the
    // retry timer frozen or backed off; try again right away instead of waiting on either.
    AppLifecycleListener(
      onResume: () {
        _loadSystemSeed();
        for (final m in _machines) {
          if (!_off.contains(m) && (parentOf(m) == null || !_off.contains(parentOf(m)!)) && !isConnected(m)) _close(m);
        }
        notifyListeners();
      },
      onStateChange: (_) {
        for (final c in _conns.values) {
          c.socket?.pingInterval = _ping;
        }
      },
    );
  }

  /// Fails harmlessly off Android (e.g. in tests).
  void _native(String method, [Object? args]) => _android.invokeMethod(method, args).ignore();

  /// A QR code's text from Play services' scanner (Android only); null if cancelled. Throws when it can't scan.
  Future<String?> scanQr() => _android.invokeMethod<String>('scan');

  int? _sdk;

  /// Android 13+ confirms a copy itself, so the app shouldn't too.
  bool get systemShowsCopies => (_sdk ?? 0) >= 33;

  StreamSubscription<FileSystemEvent>? _themeSub;
  Color? _systemBackground;
  Color? _systemDarkBackground;
  Color? _systemDarkerBackground;
  Color? _systemLighterBackground;
  Color? _systemForeground;
  String? _systemMode;

  /// Reread on every resume, since the wallpaper may have changed.
  void _loadSystemSeed() {
    if (Platform.isAndroid) {
      DynamicColorPlugin.getCorePalette().then((p) {
        if (p?.primary.get(40) == _systemPalette?.primary.get(40) && p?.neutral.get(10) == _systemPalette?.neutral.get(10)) return;
        _systemPalette = p;
        notifyListeners();
      }).ignore();
      _android.invokeMethod<int>('systemColor').then((c) {
        final seed = c == null ? null : Color(c);
        if (seed == _systemSeed) return;
        _systemSeed = seed;
        notifyListeners();
      }).ignore();
    } else if (Platform.isLinux) {
      _loadLinuxSystemSeed();
    }
  }

  void _loadLinuxSystemSeed() {
    try {
      final home = Platform.environment['HOME'];
      if (home == null) return;
      final file = File('$home/.local/state/omarchy/current/theme/colors.toml');
      if (!file.existsSync()) return;
      final lines = file.readAsLinesSync();

      Color? parseColor(String key) {
        for (final line in lines) {
          final trimmed = line.trim();
          if (trimmed.startsWith(key)) {
            final match = RegExp(r'''^\s*''' + RegExp.escape(key) + r'''\s*=\s*["']#?([0-9a-fA-F]{6})["']''').firstMatch(trimmed);
            if (match != null) {
              final hex = int.tryParse(match.group(1)!, radix: 16);
              if (hex != null) return Color(0xFF000000 | hex);
            }
          }
        }
        return null;
      }

      String? parseString(String key) {
        for (final line in lines) {
          final trimmed = line.trim();
          if (trimmed.startsWith(key)) {
            final match = RegExp(r'''^\s*''' + RegExp.escape(key) + r'''\s*=\s*["']([^"']+)["']''').firstMatch(trimmed);
            if (match != null) return match.group(1);
          }
        }
        return null;
      }

      final seed = parseColor('accent');
      final bg = parseColor('background');
      final darkBg = parseColor('dark_background');
      final darkerBg = parseColor('darker_background');
      final lighterBg = parseColor('lighter_background');
      final fg = parseColor('foreground');
      final mode = parseString('mode');

      bool changed = false;
      if (seed != _systemSeed) {
        _systemSeed = seed;
        changed = true;
      }
      if (bg != _systemBackground || darkBg != _systemDarkBackground || darkerBg != _systemDarkerBackground || fg != _systemForeground || mode != _systemMode) {
        _systemBackground = bg;
        _systemDarkBackground = darkBg;
        _systemDarkerBackground = darkerBg;
        _systemLighterBackground = lighterBg;
        _systemForeground = fg;
        _systemMode = mode;
        changed = true;
      }
      if (changed) notifyListeners();
    } catch (_) {}
  }

  void _watchLinuxTheme() {
    if (!Platform.isLinux) return;
    try {
      final home = Platform.environment['HOME'];
      if (home == null) return;
      final dir = Directory('$home/.local/state/omarchy/current');
      if (dir.existsSync()) {
        _themeSub?.cancel();
        _themeSub = dir.watch().listen((_) => _loadLinuxSystemSeed());
      }
    } catch (_) {}
  }

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

  /// Material You's tonal palettes, null before Android 12 and off Android.
  CorePalette? get systemPalette => _systemPalette;

  /// Material You's accent, null before Android 12.
  Color? get systemSeed => _systemSeed;

  /// Background colors from Omarchy's colors.toml.
  Color? get systemBackground => _systemBackground;
  Color? get systemDarkBackground => _systemDarkBackground;
  Color? get systemDarkerBackground => _systemDarkerBackground;
  Color? get systemLighterBackground => _systemLighterBackground;
  Color? get systemForeground => _systemForeground;
  String? get systemMode => _systemMode;

  /// Light or dark; null follows the system.
  Brightness? get brightness => _brightness;

  bool isConnected(String m) => _conns[m]?.connected ?? false;

  /// Why [m] can't be shown: why its connection failed (e.g. nothing answers at its address), or, once
  /// connected, why its bridge has no snapshot (e.g. "ssh: Could not resolve hostname …"); null once it can.
  String? errorOf(String m) => isConnected(m) ? _conns[m]?.error : _conns[m]?.failure;

  /// The token sent to [m]'s bridge, if one was given.
  String? tokenOf(String m) => _tokens[parentOf(m) ?? m];

  /// The headers every request to [m] carries: its bridge's token.
  Map<String, String> headersOf(String m) =>
      {if (tokenOf(m) case final token?) HttpHeaders.authorizationHeader: 'Bearer $token'};

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

  /// [m]'s SSH target (`user@host`) when a bridge reaches it, once that bridge has listed it.
  String? targetOf(String m) => _targets[m];

  /// What [m]'s agents are doing, e.g. "1 needs you · 2 working", in the alerts' words.
  String summaryOf(String m) {
    final counts = <String, int>{};
    for (final a in snapshotOf(m)?.agents ?? <AgentModel>[]) {
      // `done` lasts only until the pane is viewed: it is idle all the same.
      final status = a.displayStatus == 'done' ? 'idle' : a.displayStatus;
      counts[status] = (counts[status] ?? 0) + 1;
    }
    final text = [
      if (counts['blocked'] case final n?) '$n ${n == 1 ? 'needs' : 'need'} you',
      if (counts['working'] case final n?) '$n working',
      if (counts['monitoring'] case final n?) '$n monitoring',
      if (counts['idle'] case final n?) '$n idle',
    ].join(' · ');
    return text.isEmpty ? 'No agents' : text;
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

  /// Panes that never raise an alert, as `machine/pane_id`.
  Set<String> get muted => Set.unmodifiable(_muted);

  bool isMuted(String paneId, [String? machine]) => _muted.contains('${machine ?? this.machine}/$paneId');

  /// Silences, or unsilences, the alerts of [paneId] on [machine] (or the active machine).
  void setMuted(String paneId, bool on, [String? machine]) {
    final key = '${machine ?? this.machine}/$paneId';
    _muted = on ? {..._muted, key} : ({..._muted}..remove(key));
    SharedPreferences.getInstance().then((p) => p.setStringList('muted_panes', _muted.toList()));
    notifyListeners();
  }

  /// Unmutes all muted panes across all machines.
  void unmuteAll() {
    if (_muted.isEmpty) return;
    _muted = {};
    SharedPreferences.getInstance().then((p) => p.setStringList('muted_panes', []));
    notifyListeners();
  }

  /// Opens the system notification settings for this application on Android.
  void openNotificationSettings() => _native('openNotificationSettings');

  /// Opens battery optimization settings on Android.
  void askBattery() => _native('askBattery');

  /// Checks whether battery optimization is ignored on Android.
  Future<bool> isIgnoringBatteryOptimizations() async {
    if (!Platform.isAndroid) return true;
    try {
      final res = await _android.invokeMethod<bool>('isIgnoringBatteryOptimizations');
      return res ?? true;
    } catch (_) {
      return true;
    }
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

  EnterBehavior get enterBehavior => _enterBehavior;

  void setEnterBehavior(EnterBehavior v) {
    _enterBehavior = v;
    SharedPreferences.getInstance().then((p) => p.setString('enter_behavior', v.name));
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
    _enterBehavior = EnterBehavior.values.asNameMap()[p.getString('enter_behavior')] ?? EnterBehavior.newline;
    _muted = (p.getStringList('muted_panes') ?? []).toSet();
    _saved = {
      for (final s in p.getStringList('agent_changes') ?? [])
        if (s.split('\t') case [final k, final seq, final status, final ms])
          k: (int.parse(seq), status, DateTime.fromMillisecondsSinceEpoch(int.parse(ms)))
    };
    final alerts = p.getBool('background_alerts');
    alerts == null ? setAlerts(true) : _alerts = alerts;
    _alertBlocked = p.getBool('alert_blocked') ?? true;
    _alertFinished = p.getBool('alert_finished') ?? true;
    _alertSound = p.getBool('alert_sound') ?? true;
    _alertDesktop = p.getBool('alert_desktop') ?? true;
    setMachines(p.getStringList('herdr_machines') ?? [], p.getStringList('herdr_machine_names') ?? [],
        p.getStringList('herdr_machines_off') ?? []);
    _tokens = _pairs(p.getStringList('herdr_machine_tokens') ?? []);
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
    warmAlertSounds();
    _watchLinuxTheme();
    if (_alerts) _native('askPermissions');
    notifyListeners();
  }

  /// Every state change passes here, so the connections and the ongoing notification always mirror it.
  @override
  void notifyListeners() {
    super.notifyListeners();
    _sync();
    final on = _machines.where((m) => !_off.contains(m) && (parentOf(m) == null || !_off.contains(parentOf(m)!))).toList();
    if (!_alerts || on.isEmpty) return _native('status');
    // The title says what matters most across every machine; the text, a line per machine.
    final agents = [for (final m in on.where(isConnected)) ...?snapshotOf(m)?.agents];
    final blocked = agents.where((a) => a.status == 'blocked').length;
    final working = agents.where((a) => a.status == 'working').length;
    final monitoring = agents.where((a) => a.displayStatus == 'monitoring').length;
    _native('status', {
      'title': !on.any(isConnected)
          ? 'Reconnecting…'
          : blocked > 0
              ? '$blocked ${blocked == 1 ? 'agent needs' : 'agents need'} you'
              : working > 0
                  ? '$working ${working == 1 ? 'agent' : 'agents'} working'
                  : monitoring > 0
                      ? '$monitoring ${monitoring == 1 ? 'agent' : 'agents'} monitoring'
                      : agents.isEmpty
                          ? 'No agents running'
                          : 'All agents idle',
      'text': [
        for (final m in on) '${nameOf(m)}: ${isConnected(m) ? summaryOf(m) : errorOf(m) ?? 'reconnecting…'}'
      ].join('\n'),
    });
  }

  /// Opens a connection for every saved machine that isn't off (and whose bridge isn't off) and doesn't
  /// have one (or a retry pending).
  void _sync() {
    if (!_started || _disposed) return;
    for (final m in _machines) {
      final parent = parentOf(m);
      if (parent != null && _off.contains(parent)) continue;
      final c = _conns.putIfAbsent(m, _Conn.new);
      if (!_off.contains(m) && c.channel == null && c.retry == null) _open(m, c);
    }
  }

  /// Pings notice a connection that died silently (e.g. the phone changed networks), so it reconnects. Each
  /// wakes the phone's radio, so off screen, where only alerts need the connection, they're rarer.
  static Duration get _ping => WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed
      ? const Duration(seconds: 20)
      : const Duration(seconds: 90);

  void _open(String m, _Conn c) {
    try {
      // Without a timeout, an attempt made while the network is down can hang and never retry.
      final channel = IOWebSocketChannel(WebSocket.connect('ws://$m/ws/session', headers: headersOf(m))
          .then((s) => c.socket = s..pingInterval = _ping)
          .timeout(const Duration(seconds: 5)));
      c.channel = channel;
      // Connection failures also reach the stream's onError, which retries.
      channel.ready.ignore();
      // A closed or replaced socket's late frames are ignored.
      channel.stream.listen(
        (message) {
          if (c.channel != channel) return;
          if (!c.connected) {
            c.connected = true;
            c.failure = null;
            c.fails = 0;
            if (parentOf(m) == null) _discover(m);
            notifyListeners();
          }
          _handleMessage(m, message);
        },
        onError: (e) {
          if (!c.connected && c.channel == channel) _diagnose(m, c, e);
          _dropped(c, channel);
        },
        onDone: () => _dropped(c, channel),
      );
    } catch (_) {
      _dropped(c, null);
    }
  }

  /// After a failed connection, finds out why, so the app can say so instead of retrying quietly: a
  /// refused upgrade doesn't say why, so it asks again over HTTP, whose answer does (the token is checked
  /// first, then a reached machine's id), and a bridge that can't be reached is told apart by the error.
  Future<void> _diagnose(String m, _Conn c, Object wsError) async {
    final bridge = parentOf(m) ?? m;
    String failure;
    try {
      final res = await http
          .get(Uri.parse('http://$m/api/auth'), headers: headersOf(m))
          .timeout(const Duration(seconds: 5));
      failure = switch (res.statusCode) {
        401 => 'Wrong or missing token: run herdr-bridge --print-token on ${nameOf(bridge)} and edit the machine',
        // The bridge refuses a dotted name other than *.ts.net (DNS rebinding).
        403 => '${res.body.trim()}: add ${nameOf(bridge)} by its Tailscale IP or name',
        200 => 'The bridge answered but refused the session: ${_parseError(wsError)}',
        _ => 'The bridge answered ${res.statusCode}: ${res.body.trim()}',
      };
    } catch (e) {
      failure = _networkError(bridge, e);
    }
    debugPrint('Could not connect to $m: $failure ($wsError)');
    if (c.failure == failure) return;
    c.failure = failure;
    notifyListeners();
  }

  /// [e], a failed request to [bridge], in words the user can act on.
  static String _networkError(String bridge, Object e) {
    final host = bridge.split(':').first;
    if (e is TimeoutException) {
      return 'No answer from $host: is it on, and are this device and it both on Tailscale?';
    }
    if (e is SocketException) {
      final os = '${e.message} ${e.osError?.message}'.toLowerCase();
      if (os.contains('refused')) return 'Nothing answers at $bridge: is herdr-bridge running there, on that port?';
      if (os.contains('lookup') || os.contains('resol') || os.contains('no address')) {
        return "Can't find $host: check the address, or that Tailscale is on";
      }
      if (os.contains('unreachable')) return 'No route to $host: check this device\'s network and Tailscale';
      if (os.contains('timed out')) return 'No answer from $host: is it on, and are this device and it both on Tailscale?';
      return "Can't reach $bridge: ${e.osError?.message ?? e.message}";
    }
    return "Can't reach $bridge: $e";
  }

  /// Retries in 3 s, doubling with each failure in a row up to about 3 min, so a machine that's asleep or
  /// off the network doesn't keep the phone awake; unless [c] was closed or reopened meanwhile.
  void _dropped(_Conn c, WebSocketChannel? channel) {
    if (c.channel != channel || _disposed) return;
    c.channel = null;
    c.connected = false;
    c.retry = Timer(Duration(seconds: 3 << c.fails.clamp(0, 6)), () {
      c.retry = null;
      c.fails++;
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
    c.fails = 0;
    final channel = c.channel;
    c.channel = null;
    channel?.sink.close();
    c.connected = false;
  }

  /// Reports failed bridge requests; set by the app, which shows them as a SnackBar on any screen.
  void Function(String message)? onError;

  static const double defaultFontSize = 14;
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
  void configure(String m, {String? name, String? token, bool connect = true}) {
    _setActive(m);
    if (!_machines.contains(machine)) _machines = [..._machines, machine];
    if (name != null && name.isNotEmpty) _names = {..._names, machine: name};
    if (token != null && token.isNotEmpty) _tokens = {..._tokens, machine: token};
    if (connect) _off = {..._off}..remove(machine);
    _saveMachines();
    notifyListeners();
  }

  /// [machines] are as in [machines]; [names] are `machine=name`; [off] are the disconnected ones, as
  /// stored in prefs.
  void setMachines(List<String> machines, List<String> names, [List<String> off = const []]) {
    _machines = machines;
    _names = _pairs(names);
    _off = off.toSet();
    notifyListeners();
  }

  /// `key=value` entries, as stored in prefs.
  static Map<String, String> _pairs(List<String> entries) => {
        for (final n in entries)
          if (n.contains('=')) n.substring(0, n.indexOf('=')): n.substring(n.indexOf('=') + 1)
      };

  /// Resolves a workspace ID to the ID of its main repository workspace if it's a linked worktree.
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
    _tokens = {..._tokens}..removeWhere((k, _) => gone.contains(k));
    _off = _off.difference(gone.toSet());
    _saveMachines();
  }

  /// Saves [target] (`user@host`, or a host from the SSH config) in [bridge]'s herdr, which gets herdr
  /// ready there; the bridge then reaches it like the machines saved there already. False on failure,
  /// reported to [onError].
  Future<bool> addSshMachine(String bridge, String target, String name) async {
    final before = _machines.length;
    await _request('add $target', 'POST', '/api/machines', body: {'target': target, 'label': name}, on: bridge);
    await _discover(bridge);
    return _machines.length > before;
  }

  /// Renames [m], a machine a bridge reaches, in that bridge's herdr and, given another [target], moves it
  /// there: herdr adds it anew, so it comes back as a new machine. False on failure, reported to [onError].
  Future<bool> editSshMachine(String m, String target, String name) async {
    final bridge = parentOf(m)!;
    final res = await _request('change ${nameOf(m)}', 'POST', '/api/machines/${m.substring(m.lastIndexOf('/') + 1)}',
        body: {'target': target, 'label': name}, on: bridge);
    if (res == null) return false;
    if (name.isNotEmpty && _machines.contains(m)) _names = {..._names, m: name};
    await _discover(bridge);
    return true;
  }

  /// Removes [m], a machine a bridge reaches, from that bridge's herdr, which is where it comes from.
  Future<void> removeSshMachine(String m) async {
    final bridge = parentOf(m)!;
    await _request('remove ${nameOf(m)}', 'DELETE', '/api/machines/${m.substring(m.lastIndexOf('/') + 1)}', on: bridge);
    await _discover(bridge);
  }

  /// Renames [m] and/or moves it to [to] (`host:port`), keeping its place in the list and its on/off
  /// state. The machines it reached are found again at the new address.
  void updateMachine(String m, {required String to, required String name, String? token}) {
    _machines = [
      for (final x in _machines)
        if (x == m) to else if (x != to) x
    ];
    _names = {..._names}..remove(m);
    if (name.isNotEmpty) _names[to] = name;
    final oldToken = _tokens[m];
    final newToken = token ?? oldToken;
    if (to != m) {
      final (active, off) = (machine, _off.contains(m));
      _forget([m, ..._machines.where((x) => parentOf(x) == m)]);
      if (off) _off = {..._off, to};
      if (active == m || parentOf(active) == m) _setActive(to);
    }
    _tokens = {..._tokens}..remove(to);
    if (newToken != null && newToken.isNotEmpty) _tokens[to] = newToken;
    // A new token reconnects it, and the machines it reaches, with it.
    if (to == m && newToken != oldToken) {
      for (final x in [m, ..._machines.where((x) => parentOf(x) == m)]) {
        _conns[x]?.failure = null;
        _close(x);
      }
    }
    _saveMachines();
    notifyListeners();
  }

  /// Adds the machines [m]'s bridge reaches over SSH (those saved in its herdr) right after it, named as
  /// there, and forgets the ones it no longer does. A bridge without `/api/machines` reaches none.
  Future<void> _discover(String m) async {
    final List found;
    try {
      final res = await http.get(Uri.parse('http://$m/api/machines'), headers: headersOf(m));
      if (res.statusCode != 200) return;
      found = jsonDecode(res.body)['machines'];
    } catch (_) {
      return;
    }
    if (!_machines.contains(m)) return;
    final children = {for (final f in found) '$m/m/${f['id']}': f['label'] as String};
    _targets = {..._targets, for (final f in found) '$m/m/${f['id']}': f['target'] as String};
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
    ..setStringList('herdr_machine_tokens', [for (final e in _tokens.entries) '${e.key}=${e.value}'])
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

  /// Selects the previous tab in the active workspace.
  void previousTab() {
    final pane = selectedPane;
    final s = snapshot;
    if (pane == null || s == null) return;
    final tabs = s.tabs.where((t) => t.workspaceId == pane.workspaceId).toList();
    final idx = tabs.indexWhere((t) => t.id == pane.tabId);
    if (idx > 0) selectTab(tabs[idx - 1].id);
  }

  /// Selects the next tab in the active workspace.
  void nextTab() {
    final pane = selectedPane;
    final s = snapshot;
    if (pane == null || s == null) return;
    final tabs = s.tabs.where((t) => t.workspaceId == pane.workspaceId).toList();
    final idx = tabs.indexWhere((t) => t.id == pane.tabId);
    if (idx >= 0 && idx < tabs.length - 1) selectTab(tabs[idx + 1].id);
  }

  /// Selects tab at [index] (0-based) in the active workspace.
  void selectTabAt(int index) {
    final pane = selectedPane;
    final s = snapshot;
    if (pane == null || s == null) return;
    final tabs = s.tabs.where((t) => t.workspaceId == pane.workspaceId).toList();
    if (index >= 0 && index < tabs.length) selectTab(tabs[index].id);
  }

  /// Moves the active tab one position to the left.
  void moveTabPrevious() {
    final pane = selectedPane;
    final s = snapshot;
    if (pane == null || s == null) return;
    final tabs = s.tabs.where((t) => t.workspaceId == pane.workspaceId).toList();
    final idx = tabs.indexWhere((t) => t.id == pane.tabId);
    if (idx > 0) moveTab(tabs[idx].id, tabs[idx - 1].id);
  }

  /// Moves the active tab one position to the right.
  void moveTabNext() {
    final pane = selectedPane;
    final s = snapshot;
    if (pane == null || s == null) return;
    final tabs = s.tabs.where((t) => t.workspaceId == pane.workspaceId).toList();
    final idx = tabs.indexWhere((t) => t.id == pane.tabId);
    if (idx >= 0 && idx < tabs.length - 1) moveTab(tabs[idx].id, tabs[idx + 1].id);
  }

  static const urgency = ['blocked', 'working', 'monitoring', 'done', 'idle'];

  /// All agents across active machines, ordered as displayed on the agents page:
  /// by status urgency, then by change timestamp (most recent first), then by sequence.
  List<(String, SessionSnapshot, AgentModel, PaneModel?)> agentRows() {
    final rows = <(String, SessionSnapshot, AgentModel, PaneModel?)>[];
    for (final m in _machines) {
      if (_off.contains(m)) continue;
      final s = snapshotOf(m);
      if (s == null) continue;
      final pane = {for (final p in s.panes) p.id: p};
      for (final a in s.agents) {
        rows.add((m, s, a, pane[a.paneId]));
      }
    }
    int rank(AgentModel a) => switch (urgency.indexOf(a.displayStatus)) { -1 => urgency.length, final i => i };
    DateTime at(String m, AgentModel a) => changedAt(a.paneId, m) ?? DateTime(0);
    rows.sort((x, y) => rank(x.$3) != rank(y.$3)
        ? rank(x.$3) - rank(y.$3)
        : switch (at(y.$1, y.$3).compareTo(at(x.$1, x.$3))) {
            0 => (y.$3.stateChangeSeq ?? 0) - (x.$3.stateChangeSeq ?? 0),
            final c => c,
          });
    return rows;
  }

  /// The agent (machine, pane) [step] places from the one on screen, wrapping around,
  /// in the order shown on the agents page. Null with nowhere else to go.
  (String, String)? agentAt(int step) {
    final all = [for (final r in agentRows()) (r.$1, r.$3.paneId)];
    final i = all.indexOf((machine, selectedPaneId ?? ''));
    if (all.isEmpty || (i >= 0 && all.length == 1)) return null;
    // Off the list (a plain shell), the first step forward is the first agent, and back the last.
    final next = i < 0 ? (step > 0 ? 0 : all.length - 1) : (i + step) % all.length;
    return all[(next + all.length) % all.length];
  }

  /// Shows the agent [step] places from the one on screen ([agentAt]).
  void stepAgent(int step) {
    final (m, pane) = agentAt(step) ?? (machine, selectedPaneId ?? '');
    if (m != machine) switchMachine(m);
    if (pane.isNotEmpty) selectPane(pane);
  }

  /// Cycles to the next agent needing attention (in 'blocked' / Needs you state, or 'done' if none are blocked).
  void jumpToAttention() {
    final on = _machines
        .where((m) => !_off.contains(m) && (parentOf(m) == null || !_off.contains(parentOf(m)!)) && snapshotOf(m) != null)
        .toList();
    final urgent = <(String, String)>[];
    for (final m in on) {
      final s = snapshotOf(m);
      if (s == null) continue;
      for (final a in s.agents) {
        if (a.status == 'blocked') urgent.add((m, a.paneId));
      }
    }
    if (urgent.isEmpty) {
      for (final m in on) {
        final s = snapshotOf(m);
        if (s == null) continue;
        for (final a in s.agents) {
          if (a.status == 'done') urgent.add((m, a.paneId));
        }
      }
    }
    if (urgent.isNotEmpty) {
      final currentKey = (machine, selectedPaneId ?? '');
      final currentIdx = urgent.indexWhere((x) => x.$1 == currentKey.$1 && x.$2 == currentKey.$2);
      final next = urgent[(currentIdx + 1) % urgent.length];
      if (machine != next.$1) switchMachine(next.$1);
      selectPane(next.$2);
    }
  }

  /// [m] and, for a bridge, the machines it reaches.
  List<String> _withChildren(String m) => [m, ..._machines.where((x) => parentOf(x) == m)];

  /// Puts [m] at [to] among its siblings: a bridge among the bridges, taking the machines it reaches along,
  /// or one a bridge reaches among that bridge's others, which stay right after it. The order is the app's own.
  void moveMachine(String m, int to) {
    final parent = parentOf(m);
    final siblings = _machines.where((x) => parentOf(x) == parent).toList()
      ..remove(m)
      ..insert(to, m);
    final rest = _machines.where((x) => parentOf(x) != parent).toList();
    _machines = parent == null
        ? [for (final b in siblings) ..._withChildren(b)]
        : (rest..insertAll(rest.indexOf(parent) + 1, siblings));
    _saveMachines();
    notifyListeners();
  }

  /// Disconnects [m] (the active machine by default), closing its connection (and those it reaches),
  /// and keeps it off until [connect]ed.
  void disconnect([String? m]) {
    final target = m ?? machine;
    _off = {..._off, target};
    _withChildren(target).forEach(_close);
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
      // The bridge pushes a snapshot whenever it changed, or why it has none. An older bridge also
      // forwards raw events, which are ignored: the snapshot that follows carries their change.
      if (type == 'snapshot') {
        _conns[m]?.error = null;
        _apply(m, SessionSnapshot.fromJson(data['data']));
      } else if (type == 'error') {
        _conns[m]?.error = data['error'].toString();
        notifyListeners();
      } else if (type == 'delivery') {
        _delivered(Delivery(m, data));
      }
    } catch (e) {
      debugPrint('Error parsing session WS message: $e');
    }
  }

  void _apply(String m, SessionSnapshot snapshot) {
    final c = _conns.putIfAbsent(m, _Conn.new);
    final before = c.raw;
    c.raw = snapshot;
    _show(m);
    // After a dropout [before] is the last snapshot seen, so what changed meanwhile still alerts.
    if (before != null && _alerts) _alertChanges(m, before, snapshot);
    // herdr reuses a closed pane's id: a new pane mustn't come up muted, nor inherit the old one's
    // completion count, which would hold back its "Finished" alerts.
    c.completions.removeWhere((id, _) => !snapshot.panes.any((p) => p.id == id));
    c.changes.removeWhere((id, _) => !snapshot.agents.any((a) => a.paneId == id));
    _deliveries.removeWhere((d) => d.machine == m && d.paneId != null && !snapshot.panes.any((p) => p.id == d.paneId));
    for (final a in snapshot.agents) {
      final was = c.changes[a.paneId];
      final seq = a.stateChangeSeq ?? 0;
      // A higher seq is a change; an older snapshot landing late (lower seq) isn't. Nor is `done` turning
      // `idle` when the pane is viewed: herdr leaves the seq as it was. Without seqs, a new status is.
      if (was == null || seq > was.$1 || seq == 0 && a.status != was.$2) {
        final kept = _saved['$m/${a.paneId}'];
        c.changes[a.paneId] = (
          seq,
          a.status,
          before != null
              ? DateTime.now()
              : kept != null && kept.$1 == seq && (seq != 0 || kept.$2 == a.status)
                  ? kept.$3
                  : null
        );
      }
    }
    final saved = {..._saved}
      ..removeWhere((k, _) => k.substring(0, k.lastIndexOf('/')) == m)
      ..addAll({
        for (final MapEntry(:key, :value) in c.changes.entries)
          if (value.$3 case final at?) '$m/$key': (value.$1, value.$2, at)
      });
    if (saved.length != _saved.length || saved.entries.any((e) => _saved[e.key] != e.value)) {
      _saved = saved;
      final list = [
        for (final MapEntry(:key, :value) in saved.entries)
          '$key\t${value.$1}\t${value.$2}\t${value.$3.millisecondsSinceEpoch}'
      ];
      SharedPreferences.getInstance().then((p) => p.setStringList('agent_changes', list));
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

  /// Panes, tabs and workspaces (`machine/id`) closed but still undoable: left out of what's shown until
  /// they're closed or the close is undone ([closeUnlessUndone]).
  final _hidden = <String>{};

  /// Shows [m]'s snapshot less what's [_hidden], moving to another pane if the selected one went.
  void _show(String m) {
    final c = _conns[m]!;
    final s = c.raw!;
    bool hidden(String id) => _hidden.contains('$m/$id');
    final before = c.snapshot;
    final tabs = s.tabs.where((t) => !hidden(t.id) && !hidden(t.workspaceId)).toList();
    final panes = s.panes.where((p) => !hidden(p.id) && tabs.any((t) => t.id == p.tabId)).toList();
    final now = c.snapshot = _hidden.isEmpty
        ? s
        : SessionSnapshot(
            focusedPaneId: s.focusedPaneId,
            workspaces: s.workspaces.where((w) => !hidden(w.id)).toList(),
            tabs: tabs,
            panes: panes,
            agents: s.agents.where((a) => panes.any((p) => p.id == a.paneId)).toList(),
          );
    final wasInBefore = before?.panes.any((p) => p.id == c.selectedPaneId) ?? false;
    if (c.selectedPaneId == null || (wasInBefore && !now.panes.any((p) => p.id == c.selectedPaneId))) {
      // Everything hidden isn't herdr left empty: no new workspace for that.
      c.selectedPaneId = now.panes.isEmpty && s.panes.isNotEmpty ? null : _fallbackPane(m, c.selectedPaneId, before, now);
    }
  }

  /// Hides [keys] (`machine/id` of panes, tabs or workspaces) at once, and once [undone] completes shows
  /// them again: after [close] has closed them, unless it was undone, which also selects again the pane that
  /// was selected if the close took it away.
  Future<void> closeUnlessUndone(List<String> keys, Future<bool> undone, Future<void> Function() close) async {
    void show() {
      for (final m in _conns.keys) {
        if (_conns[m]!.raw != null) _show(m);
      }
      notifyListeners();
    }

    final selected = {for (final e in _conns.entries) e.key: e.value.selectedPaneId};
    _hidden.addAll(keys);
    show();
    selected.removeWhere((m, id) => _conns[m]!.selectedPaneId == id);
    final wasUndone = await undone;
    if (!wasUndone) await close();
    _hidden.removeAll(keys);
    show();
    if (wasUndone) {
      for (final e in selected.entries) {
        final c = _conns[e.key]!;
        if (e.value != null && c.snapshot?.panes.any((p) => p.id == e.value) == true) c.selectedPaneId = e.value;
      }
      notifyListeners();
    }
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
      if (_muted.contains('$m/${pane.id}')) continue;

      final wasBlocked = wasAgent?.status == 'blocked' || was?.agentStatus == 'blocked';
      final blocked = !wasBlocked && (agent?.status == 'blocked' || pane.agentStatus == 'blocked');
      final finished = wasAgent != null && seq > seen;
      if (!blocked && !finished) continue;
      if (blocked && !_alertBlocked) continue;
      if (finished && !_alertFinished) continue;
      final agentName = (agent?.name.isNotEmpty == true ? agent?.name : wasAgent?.name) ?? '';
      // "Claude needs you", what it's on, and where it runs.
      final who = agentName.isEmpty ? 'An agent' : agentName[0].toUpperCase() + agentName.substring(1);
      final title = '$who ${blocked ? 'needs you' : 'finished'}';
      final place = [now.placeOf(pane), nameOf(m)].where((s) => s.isNotEmpty).join(' · ');
      final iconName = agentName.isNotEmpty ? agentName : pane.terminalTitle;
      final iconBytes = agentIconBytes(iconName);
      if (!watching || pane.id != selectedPaneId) {
        _native('alert', {
          'key': '$m/${pane.id}',
          'title': title,
          'text': pane.terminalTitle,
          'place': place,
          'machine': m,
          'pane': pane.id,
          'urgent': blocked,
          if (iconBytes != null) 'icon': iconBytes,
        });
      }
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
            [pane.terminalTitle, place].where((s) => s.isNotEmpty).join('\n'),
          ]).ignore();
        }
        if (_alertSound) {
          final file = File('${Directory.systemTemp.path}/${blocked ? 'herdr_blocked.mp3' : 'herdr_done.mp3'}');
          final path = file.existsSync() ? file.path : null;
          final soundName = blocked ? 'dialog-warning' : 'complete';

          void playFallback() {
            Process.run('canberra-gtk-play', ['-i', soundName]).then((res) {
              if (res.exitCode != 0) {
                Process.run('paplay', ['/usr/share/sounds/freedesktop/stereo/$soundName.oga']).then((res2) {
                  if (res2.exitCode != 0) {
                    Process.run('pw-play', ['/usr/share/sounds/freedesktop/stereo/$soundName.oga']).ignore();
                  }
                }).ignore();
              }
            }).ignore();
          }

          if (path != null) {
            Process.run('pw-play', [path]).then((res) {
              if (res.exitCode != 0) {
                Process.run('paplay', [path]).then((res2) {
                  if (res2.exitCode != 0) playFallback();
                }).ignore();
              }
            }).ignore();
          } else {
            playFallback();
            warmAlertSounds().ignore();
          }
        }
      }
    }
  }

  /// Files sent to [paneId] on [m], oldest first: its agent's, and those of agents in another herdr session.
  List<Delivery> deliveriesOf(String m, String? paneId) =>
      _deliveries.where((d) => d.machine == m && (d.paneId == null || d.paneId == paneId)).toList();

  void dismissDelivery(Delivery d) {
    _deliveries.remove(d);
    _native('cancel', {'key': '${d.machine}/delivery/${d.id}'});
    notifyListeners();
  }

  /// Offers a file an agent sent on its pane and, unless that pane is on screen or muted, alerts with a
  /// button that opens it. The bridge sends none to the app on its own machine, which already has the file.
  void _delivered(Delivery d) {
    final m = d.machine;
    _deliveries.add(d);
    notifyListeners();
    final watching = m == machine && WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    if (!_alerts || watching && (d.paneId == null || d.paneId == selectedPaneId)) return;
    if (d.paneId != null && _muted.contains('$m/${d.paneId}')) return;
    final snap = snapshotOf(m);
    final pane = snap?.panes.where((p) => p.id == d.paneId).firstOrNull;
    final agentName = snap?.agents.where((a) => a.paneId == d.paneId).firstOrNull?.name ?? '';
    final who = agentName.isEmpty ? 'An agent' : agentName[0].toUpperCase() + agentName.substring(1);
    final title = '$who sent ${d.name}';
    final place = [if (pane != null) snap!.placeOf(pane), nameOf(m)].where((s) => s.isNotEmpty).join(' · ');
    if (Platform.isAndroid) {
      final iconBytes = agentIconBytes(agentName);
      _native('alert', {
        'key': '$m/delivery/${d.id}',
        'title': title,
        'text': d.detail,
        'place': place,
        'machine': m,
        'pane': d.paneId ?? '',
        'urgent': false,
        'delivery': d.id,
        'action': d.isApk ? 'Install' : 'Open',
        if (iconBytes != null) 'icon': iconBytes,
      });
    } else if (Platform.isLinux && _alertDesktop) {
      Process.run('notify-send', ['-a', 'Herdr', '-i', agentIconPath(agentName) ?? 'document-save', title, '${d.detail}\n$place'])
          .ignore();
    }
  }

  /// Downloads [d] (once) and opens it: on Android with the app for its type, the installer for an APK;
  /// on Linux it is saved to the Downloads folder and opened from there.
  Future<void> openDelivery(Delivery d) async {
    if (d.progress.value != null) return;
    try {
      var path = d.path;
      if (path == null || !File(path).existsSync()) {
        d.progress.value = 0;
        path = d.path = await _download(d);
      }
      if (Platform.isAndroid) {
        await _android.invokeMethod('openFile', {'path': path, 'mime': d.mime});
      } else {
        await Process.run('xdg-open', [path]);
      }
    } catch (e) {
      onError?.call('Could not open ${d.name}: ${e is PlatformException ? e.message : _parseError(e)}');
    } finally {
      d.progress.value = null;
    }
  }

  /// Opens [url] in the system's browser.
  @visibleForTesting
  Future<void> Function(String url)? onOpenUrl;

  Future<void> openUrl(String url) async {
    try {
      if (onOpenUrl != null) {
        await onOpenUrl!(url);
        return;
      }
      if (Platform.isAndroid) {
        await _android.invokeMethod('openUrl', {'url': url});
      } else {
        await Process.run('xdg-open', [url]);
      }
    } catch (e) {
      onError?.call('Could not open link: ${e is PlatformException ? e.message : _parseError(e)}');
    }
  }

  Future<String> _download(Delivery d) async {
    final String dir;
    if (Platform.isAndroid) {
      // The app's cache, which its FileProvider shares with the app that opens it. Only the files still
      // offered are kept: an APK runs to tens of MB.
      dir = (await _android.invokeMethod<String>('deliveriesDir'))!;
      final kept = {for (final o in _deliveries) o.path};
      for (final f in Directory(dir).listSync()) {
        if (!kept.contains(f.path)) f.deleteSync();
      }
    } else {
      final xdg = await Process.run('xdg-user-dir', ['DOWNLOAD']).then((r) => (r.stdout as String).trim(), onError: (_) => '');
      dir = xdg.isNotEmpty ? xdg : '${Platform.environment['HOME']}/Downloads';
    }
    // A bridge's name for it never holds a slash, but a name is no path to trust.
    final name = d.name.replaceAll('/', '_');
    var file = File('$dir/$name');
    final dot = name.lastIndexOf('.');
    for (var i = 1; !Platform.isAndroid && file.existsSync(); i++) {
      file = File('$dir/${dot > 0 ? '${name.substring(0, dot)} ($i)${name.substring(dot)}' : '$name ($i)'}');
    }
    final req = http.Request('GET', Uri.parse('http://${d.machine}/api/deliveries/${d.id}'))
      ..headers.addAll(headersOf(d.machine));
    final res = await req.send();
    if (res.statusCode != 200) throw await res.stream.bytesToString();
    final sink = file.openWrite();
    var got = 0;
    try {
      await for (final chunk in res.stream) {
        sink.add(chunk);
        got += chunk.length;
        d.progress.value = d.size > 0 ? got / d.size : 1;
      }
      await sink.close();
    } catch (_) {
      // Half a file isn't left behind.
      await sink.close().catchError((_) {});
      if (file.existsSync()) file.deleteSync();
      rethrow;
    }
    return file.path;
  }

  Future<void> _fetchSnapshotHttp(String m) async {
    try {
      final res = await http.get(Uri.parse('http://$m/api/snapshot'), headers: headersOf(m));
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
      final req = http.Request(method, Uri.parse('http://$m$path').replace(queryParameters: query))
        ..headers.addAll(headersOf(m));
      if (body != null) {
        req.headers['Content-Type'] = 'application/json';
        req.body = jsonEncode(body);
      }
      final res = await http.Response.fromStream(await req.send());
      if (res.statusCode != 200) throw res.body;
      result = res.body.isEmpty ? null : jsonDecode(res.body);
    } catch (e) {
      debugPrint('$method $m$path failed: $e');
      onError?.call('Could not $what: ${e is SocketException || e is TimeoutException ? _networkError(parentOf(m) ?? m, e) : _parseError(e)}');
    }
    unawaited(_fetchSnapshotHttp(m));
    return result;
  }

  /// POSTs to a route that creates a tab or workspace, then shows its root pane, unless another
  /// machine was put on screen meanwhile.
  Future<bool> _create(String what, String path, Map<String, dynamic> body, {String? on}) async {
    final m = on ?? machine;
    final res = await _request(what, 'POST', path, body: body, on: m);
    final paneId = res is Map ? (res['root_pane']?['pane_id']) : null;
    if (paneId is String && m == machine) selectPane(paneId);
    return paneId is String && m == machine;
  }

  String _parseError(dynamic e) {
    try {
      // The bridge words herdr's own errors as "Herdr error response: {code, message}".
      final text = e.toString();
      final data = jsonDecode(text.substring(text.indexOf('{')));
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

  /// Uploads image [bytes] to the active machine's bridge, which saves them where its agents run.
  /// Returns the saved path for `@`-references, or null (already reported to [onError]).
  Future<String?> uploadImage(List<int> bytes, String mime) async {
    final res = await _request('upload image', 'POST', '/api/uploads',
        body: {'mime': mime, 'data': base64Encode(bytes)});
    return res is Map ? res['path'] as String? : null;
  }

  Future<void> closeTab(String tabId, [String? m]) => _request('close tab', 'DELETE', '/api/tab/$tabId', on: m);

  /// Clears [paneId]'s screen and scrollback, keeping its prompt line (`pane.clear`; full-screen apps are left alone).
  Future<void> clearPane(String paneId) => _request('clear pane', 'POST', '/api/pane/clear', body: {'pane_id': paneId});

  /// Closes [paneId] on [m] (the active machine by default). herdr closes a tab with its last pane and a
  /// workspace with its last tab, so when this is the workspace's only pane it first opens a new tab
  /// there, leaving the workspace with a shell.
  Future<void> closePane(String paneId, [String? m]) async {
    // What herdr has, panes hidden to close included.
    final panes = _conns[m ?? machine]?.raw?.panes ?? const [];
    final ws = panes.where((p) => p.id == paneId).firstOrNull?.workspaceId;
    if (ws != null && panes.where((p) => p.workspaceId == ws).length == 1) {
      await _request('create tab', 'POST', '/api/tab', body: {'workspace_id': ws}, on: m);
    }
    final raw = _conns[m ?? machine]?.raw;
    raw?.panes.removeWhere((p) => p.id == paneId);
    raw?.agents.removeWhere((a) => a.paneId == paneId);
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

  /// Closes a workspace, or with [closeGroup] a repository's main workspace with its linked worktrees' (herdr
  /// refuses to close it alone), or with [removeWorktree] deletes a linked worktree's checkout, which herdr
  /// refuses while it has changes unless [force]d (the caller asks, since herdr's reason for refusing is the
  /// only sign of that). A checkout's branch stays.
  Future<void> deleteWorkspace(String workspaceId,
      {bool closeGroup = false, bool removeWorktree = false, bool force = false, String? on}) {
    final query = {
      if (closeGroup) 'close_group': 'true',
      if (removeWorktree) 'remove_worktree': 'true',
      if (force) 'force': 'true',
    };
    return _request(removeWorktree ? 'delete worktree' : 'close workspace', 'DELETE', '/api/workspace/$workspaceId',
        query: query.isEmpty ? null : query, on: on);
  }

  Future<void> renameWorkspace(String workspaceId, String label, {String? on}) =>
      _request('rename workspace', 'POST', '/api/workspace/$workspaceId/rename', body: {'label': label}, on: on);

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

  /// A new worktree of a repository's main workspace, on [branch] (checked out if it exists, else made from
  /// the main checkout's HEAD).
  Future<bool> createWorktree(String workspaceId, String branch, {String? on}) =>
      _create('create worktree', '/api/worktree', {'workspace_id': workspaceId, 'branch': branch}, on: on);

  Future<List<Map<String, dynamic>>?> listWorktrees(String workspaceId, {String? on}) async {
    final res = await _request('list worktrees', 'GET', '/api/worktree', query: {'workspace_id': workspaceId}, on: on);
    if (res == null) return null;
    return ((res is Map ? res['worktrees'] : null) as List<dynamic>? ?? []).cast<Map<String, dynamic>>();
  }

  /// Opens the worktree checked out at [path] in a workspace of its own, next to its repository's main [workspaceId].
  Future<bool> openWorktree(String workspaceId, String path, {String? on}) =>
      _create('open worktree', '/api/worktree/open', {'workspace_id': workspaceId, 'path': path}, on: on);

  @override
  void dispose() {
    _disposed = true;
    _themeSub?.cancel();
    _conns.keys.toList().forEach(_close);
    super.dispose();
  }
}

/// Extracts and caches the bundled herdr sound files on Linux.
Future<void> warmAlertSounds() async {
  if (!Platform.isLinux) return;
  for (final name in const ['herdr_blocked.mp3', 'herdr_done.mp3']) {
    try {
      final file = File('${Directory.systemTemp.path}/$name');
      final data = await rootBundle.load('assets/sounds/$name');
      final bytes = data.buffer.asUint8List();
      if (!file.existsSync() || file.lengthSync() != bytes.length) {
        file.writeAsBytesSync(bytes);
      }
    } catch (_) {}
  }
}
