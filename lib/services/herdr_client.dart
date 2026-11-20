import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:material_color_utilities/material_color_utilities.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/session.dart';
import '../ui/widgets/agent_avatar.dart';
import 'hc.dart';

/// What the volume keys do on the terminal screen; [volume] leaves them to the system.
enum VolumeKeys { fontSize, arrows, volume }

/// What Enter does in the message box; [newline] inserts a new line (Ctrl+Enter sends),
/// [send] sends the message (Shift+Enter inserts a new line).
enum EnterBehavior { newline, send }

/// One machine's state: for a machine the phone dials ([HerdrClientService.parentOf] null), its herdr-core
/// link; for one that core reaches, the root's link carries it. Its terminals and layout make [raw].
class _Conn {
  /// The SSH link to this machine's herdr-core, once connected; roots only.
  HcLink? link;
  bool dialing = false;

  /// The connect attempt in flight; any other that completes is stale and let go.
  Object? attempt;
  Timer? retry;

  /// Failed attempts in a row, which space the retries out.
  int fails = 0;
  bool connected = false;

  /// What herdr-core and the layout make, and what's shown of it: the same, less anything closed but still undoable.
  SessionSnapshot? raw;
  SessionSnapshot? snapshot;
  String? selectedPaneId;

  /// Why the machine has nothing to show while its link is up (its line from the root is down).
  String? error;

  /// Why the last attempt to connect failed, in words the user can act on, until one succeeds.
  String? failure;

  /// The highest `turn` seen per terminal, so going back and forth never alerts twice.
  final completions = <String, int>{};

  /// Its live terminals by local address (`t7`), as herdr-core's records, and the Herdr app's layout
  /// (its `herdr-app` document: spaces, tabs, panes), null without the app.
  final terminals = <String, Map>{};
  Map? layout;

  /// Subscription usage by agent (`claude`, `opencode`…) as the herdr-usage mod keeps it in the Herdr app's
  /// `shared.json` on this machine; roots only, the same account everywhere.
  Map usage = const {};
}

/// Every saved machine keeps its own connection, so several can be connected at once; each can be
/// disconnected on its own. A machine is an SSH target (`user@host[:port]`) the phone dials, or
/// `<target>/m/<name>`, a machine that one's herdr-core has added (`hc machine ls`). The *active* machine
/// ([machine]) is just the one on screen: [snapshot], [selectedPaneId] and the requests below are its.
class HerdrClientService extends ChangeNotifier {
  String _machine = '';
  double _fontSize = defaultFontSize;
  Color? _seed;
  Color? _systemSeed;
  CorePalette? _systemPalette;
  Brightness? _brightness;
  List<String> _machines = [];
  Map<String, String> _names = {};

  /// The SSH target of each machine another machine's herdr-core reaches, as that core has it.
  Map<String, String> _targets = {};

  /// Each dialed host's key fingerprint, trusted on first use (pref `ssh_host_keys`, `target=fingerprint`).
  Map<String, String> _hostKeys = {};

  /// This phone's SSH key (pref `ssh_key`), made on first use.
  PhoneKey? _key;

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
  EnterBehavior _enterBehavior = EnterBehavior.newline;
  bool _started = false;
  bool _disposed = false;
  final _conns = <String, _Conn>{};

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
          // One still dialing is left to finish (it times out): another would race it.
          if (!_off.contains(m) && (parentOf(m) == null || !_off.contains(parentOf(m)!)) && !isConnected(m) &&
              _conns[m]?.dialing != true) {
            _close(m);
          }
        }
        discoverMachines();
        _startDiscoveryTimer();
        notifyListeners();
      },
      onPause: _stopDiscoveryTimer,
      onHide: _stopDiscoveryTimer,
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
      _android.invokeMethod<List<Object?>>('systemPalette').then((l) {
        final p = l == null ? null : CorePalette.fromList(l.cast<int>());
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

  /// Why [m] can't be shown: why its connection failed (e.g. the key isn't authorized there), or, once
  /// connected, why its line from the machine that reaches it is down; null once it can.
  String? errorOf(String m) => isConnected(m) ? _conns[m]?.error : _conns[m]?.failure;

  /// The line for a machine's `~/.ssh/authorized_keys` that lets this phone in.
  String get publicKey => (_key ??= _loadKey()).publicLine;

  PhoneKey _loadKey() {
    final prefs = _prefs;
    var pem = prefs?.getString('ssh_key');
    if (pem == null) {
      pem = PhoneKey.generatePem();
      prefs?.setString('ssh_key', pem);
    }
    return PhoneKey.fromPem(pem);
  }

  SharedPreferences? _prefs;

  /// The machine whose herdr-core reaches [m] (`<target>/m/<name>`, from its `hc machine ls`), or null when
  /// the phone dials [m] itself.
  static String? parentOf(String m) {
    final i = m.indexOf('/m/');
    return i > 0 ? m.substring(0, i) : null;
  }

  /// Whether [m] is a valid SSH target (`user@host[:port]`) or a machine one reaches (`<target>/m/<name>`).
  static bool isValidMachine(String m) {
    final parts = m.split('/m/');
    if (parts.length == 1) return !m.contains('/');
    if (parts.length == 2) return !parts[0].contains('/') && !parts[1].contains('/') && parts[1].isNotEmpty;
    return false;
  }

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

  @visibleForTesting
  void handleNotificationForTesting(String root, Map notification) => _onNotification(root, notification);

  @visibleForTesting
  void resetForTesting(String root, List terminals, [Map? layout]) {
    _conns.putIfAbsent(root, _Conn.new).layout = layout;
    _reset(root, terminals);
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
      final status = a.status == 'done' ? 'idle' : a.status;
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

  /// When the agent in [paneId] on [machine] (or the active machine) last changed status (herdr-core's
  /// `status_ms`, or when this app heard of a change since).
  DateTime? changedAt(String paneId, [String? machine]) => switch (snapshotOf(machine ?? this.machine)?.agentOf(paneId)?.stateChangeSeq) {
        final int ms when ms > 0 => DateTime.fromMillisecondsSinceEpoch(ms),
        _ => null,
      };

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
    _prefs = p;
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
    final alerts = p.getBool('background_alerts');
    alerts == null ? setAlerts(true) : _alerts = alerts;
    _alertBlocked = p.getBool('alert_blocked') ?? true;
    _alertFinished = p.getBool('alert_finished') ?? true;
    _alertSound = p.getBool('alert_sound') ?? true;
    _alertDesktop = p.getBool('alert_desktop') ?? true;
    // Machines are SSH targets now; the bridge's `herdr_machines` (host:port) are left behind.
    setMachines(p.getStringList('hc_machines') ?? [], p.getStringList('hc_machine_names') ?? [],
        p.getStringList('hc_machines_off') ?? []);
    _hostKeys = _pairs(p.getStringList('ssh_host_keys') ?? []);
    final active = p.getString('hc_active');
    _machine = active != null && _machines.contains(active) ? active : _machines.firstOrNull ?? '';
  }

  /// Opens the connections, once the saved state is loaded.
  void start() {
    _started = true;
    warmAgentIcons();
    warmAlertSounds();
    _watchLinuxTheme();
    _startDiscoveryTimer();
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
    _native('status', {
      'title': !on.any(isConnected)
          ? 'Reconnecting…'
          : blocked > 0
              ? '$blocked ${blocked == 1 ? 'agent needs' : 'agents need'} you'
              : working > 0
                  ? '$working ${working == 1 ? 'agent' : 'agents'} working'
                  : agents.isEmpty
                      ? 'No agents running'
                      : 'All agents idle',
      'text': [
        for (final m in on) '${nameOf(m)}: ${isConnected(m) ? summaryOf(m) : errorOf(m) ?? 'reconnecting…'}'
      ].join('\n'),
    });
  }

  /// Dials every saved machine that isn't off and has no link (nor an attempt or a retry pending). A machine
  /// another one's core reaches comes with that one's link.
  void _sync() {
    if (!_started || _disposed) return;
    for (final m in _machines) {
      final c = _conns.putIfAbsent(m, _Conn.new);
      if (parentOf(m) == null && !_off.contains(m) && c.link == null && !c.dialing && c.retry == null) _open(m, c);
    }
  }

  /// Trusts a host's key the first time, and only that key afterwards.
  bool _trust(String target, String fingerprint) {
    final known = _hostKeys[target];
    if (known != null) return known == fingerprint;
    _hostKeys = {..._hostKeys, target: fingerprint};
    _prefs?.setStringList('ssh_host_keys', [for (final e in _hostKeys.entries) '${e.key}=${e.value}']);
    return true;
  }

  /// Forgets [m]'s host key, so the next connection trusts the one it shows (after the machine was reinstalled).
  void forgetHostKey(String m) {
    _hostKeys = {..._hostKeys}..remove(m);
    _prefs?.setStringList('ssh_host_keys', [for (final e in _hostKeys.entries) '${e.key}=${e.value}']);
    _conns[m]?.failure = null;
    _close(m);
    notifyListeners();
  }

  Future<void> _open(String m, _Conn c) async {
    c.dialing = true;
    final attempt = c.attempt = Object();
    HcLink? link;
    try {
      // Without a timeout, an attempt made while the network is down can hang and never retry; one that
      // answers after it is closed.
      final opening = HcLink.open(m, _key ??= _loadKey(), (fp) => _trust(m, fp));
      link = await opening.timeout(const Duration(seconds: 30), onTimeout: () {
        opening.then((l) => l.dispose()).ignore();
        throw TimeoutException('connect', const Duration(seconds: 30));
      });
      if (c.attempt != attempt) return link.dispose(); // closed or redialed meanwhile
      c.link = link;
      final first = await link.subscribe((n) => _onNotification(m, n));
      if (c.attempt != attempt) return; // closed meanwhile: _close disposed it
      c
        ..dialing = false
        ..connected = true
        ..failure = null
        ..fails = 0;
      _reset(m, first['terminals']);
      final dropped = link;
      link.done.then((why) => _dropped(m, c, dropped, why));
      await _discover(m);
      await _fetchLayouts(m);
      await _fetchUsage(m);
    } catch (e) {
      link?.dispose();
      if (c.attempt != attempt) return;
      c.failure = _words(m, e);
      debugPrint('Could not connect to $m: $e');
      _dropped(m, c, link, null);
    }
  }

  /// [e], a failed connection to [m], in words the user can act on.
  String _words(String m, Object e) {
    final host = m.substring(m.lastIndexOf('@') + 1).split(':').first;
    final text = '$e';
    final low = text.toLowerCase();
    if (e is TimeoutException) return 'No answer from $host: is it on, and are this device and it both on Tailscale?';
    if (low.contains('hostkey') || low.contains('host key')) {
      return "$host's host key changed. If it was reinstalled, forget its key on its page and connect again";
    }
    if (low.contains('auth')) return "$host didn't accept this phone's key: add it to ~/.ssh/authorized_keys there (Settings shows it)";
    if (low.contains('not installed')) return 'herdr-core is not installed on $host';
    if (e is SocketException) {
      final os = '${e.message} ${e.osError?.message}'.toLowerCase();
      if (os.contains('refused')) return 'Nothing answers on $host\'s SSH port: is SSH on there?';
      if (os.contains('lookup') || os.contains('resol') || os.contains('no address')) {
        return "Can't find $host: check the address, or that Tailscale is on";
      }
      if (os.contains('unreachable')) return "No route to $host: check this device's network and Tailscale";
      return "Can't reach $host: ${e.osError?.message ?? e.message}";
    }
    return "Can't reach $host: $text";
  }

  /// Retries in 3 s, doubling with each failure in a row up to about 3 min, so a machine that's asleep or
  /// off the network doesn't keep the phone awake; unless [m] was closed or reopened meanwhile.
  void _dropped(String m, _Conn c, HcLink? link, String? why) {
    if (c.link != link || _disposed) return;
    if (why != null && c.connected) c.failure = _words(m, why);
    c
      ..attempt = null
      ..link = null
      ..dialing = false
      ..connected = false;
    for (final x in _machines.where((x) => parentOf(x) == m)) {
      _conns[x]?.connected = false;
    }
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
    c.dialing = false;
    c.attempt = null;
    final link = c.link;
    c.link = null;
    link?.dispose();
    c.connected = false;
  }

  /// The link that reaches [m]'s terminals now, and [pane]'s address through it, for a terminal stream.
  HcLink? linkOf(String m) => _route(m).$1;
  String addressOf(String m, String pane) => '${_route(m).$2}$pane';

  /// [m]'s root link and the address prefix of its terminals as seen through it (`rohan/` for a machine
  /// that root's core added).
  (HcLink?, String) _route(String m) {
    final root = parentOf(m);
    return root == null ? (_conns[m]?.link, '') : (_conns[root]?.link, '${m.substring(m.lastIndexOf('/') + 1)}/');
  }

  /// The machine (as in [machines]) and local address of [address], seen from [root]'s core.
  (String, String) _local(String root, String address) {
    final slash = address.indexOf('/');
    return slash < 0 ? (root, address) : ('$root/m/${address.substring(0, slash)}', address.substring(slash + 1));
  }

  /// Replaces every terminal of [root] and the machines its core reaches.
  void _reset(String root, List terminals) {
    for (final m in [root, ..._machines.where((x) => parentOf(x) == root)]) {
      _conns.putIfAbsent(m, _Conn.new).terminals.clear();
    }
    for (final Map t in terminals) {
      final (m, local) = _local(root, t['address']);
      _conns.putIfAbsent(m, _Conn.new).terminals[local] = t;
    }
    for (final m in [root, ..._machines.where((x) => parentOf(x) == root)]) {
      _rebuild(m);
    }
  }

  /// One notification of [root]'s event stream, applied as herdr-core's `schema/README.md` says.
  void _onNotification(String root, Map n) {
    final p = n['params'] as Map? ?? const {};
    switch (n['method']) {
      case 'missed':
        _reset(root, p['terminals'] ?? const []);
        _fetchLayouts(root);
      case 'event':
        final data = p['data'];
        if (p['type'] == 'doc') {
          if (data?['name'] == 'herdr-app') _fetchLayout(p['machine'] == null ? root : '$root/m/${p['machine']}');
          return;
        }
        final (m, local) = _local(root, p['terminal'] ?? '');
        final c = _conns.putIfAbsent(m, _Conn.new);
        final t = c.terminals[local];
        switch (p['type']) {
          case 'created' || 'restarted':
            c.terminals[local] = Map.of(data);
          case 'removed' || 'finished':
            c.terminals.remove(local);
          case 'status' when t != null:
            // Updates that only change the title or records keep when the state last changed.
            if ((t['status'] as Map?)?['state'] != (data['status'] as Map?)?['state']) {
              t['status_ms'] = DateTime.now().millisecondsSinceEpoch;
            }
            t['status'] = data['status'];
            t['reported'] = data['reported'];
          case 'turn' when t != null:
            t['turn'] = data['turn'];
            if (m == machine && local == c.selectedPaneId &&
                WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
              _markSeen(m, local);
            }
          case 'title' when t != null:
            t['title'] = data['title'];
          case 'labels' when t != null || data['record'] != null:
            if (data['record'] != null) c.terminals[local] = Map.of(data['record']);
            c.terminals[local]!['labels'] = data['labels'];
          case 'foreground' when t != null:
            t['foreground'] = data;
          default:
            return;
        }
        _rebuild(m);
    }
  }

  /// Reads the Herdr app's layout of [root] and of the machines its core reaches.
  Future<void> _fetchLayouts(String root) async {
    await Future.wait([for (final m in [root, ..._machines.where((x) => parentOf(x) == root)]) _fetchLayout(m)]);
  }

  Future<void> _fetchLayout(String m) async {
    final (link, prefix) = _route(m);
    if (link == null) return;
    try {
      final res = await link.call('doc.get', {'name': 'herdr-app', if (prefix.isNotEmpty) 'on': prefix.substring(0, prefix.length - 1)});
      _conns.putIfAbsent(m, _Conn.new)
        ..layout = res['value'] as Map?
        ..error = null;
    } on HcError catch (e) {
      _conns[m]?.error = e.kind == 'unavailable' || e.kind == 'machine_unknown' ? e.message : null;
    }
    _rebuild(m);
  }

  /// The snapshot the screens show, made from [m]'s terminals and the Herdr app's layout: each space a
  /// workspace, each tab a tab, each terminal in a tab's panes a pane (by its address), and each terminal
  /// whose program reports its status an agent. Agents in no tab (sub-agents, `hc run`) are panes of none.
  void _rebuild(String m) {
    final c = _conns[m];
    if (c == null) return;
    final live = {for (final e in c.terminals.entries) if (e.value['state'] != 'finished') e.key: e.value};
    final workspaces = <WorkspaceModel>[], tabs = <TabModel>[], panes = <PaneModel>[], agents = <AgentModel>[];

    void add(String address, String space, String tab) {
      final t = live[address]!;
      final fg = t['foreground'] as Map?;
      panes.add(PaneModel.fromJson({
        'pane_id': address,
        'workspace_id': space,
        'tab_id': tab,
        'title': t['title'] ?? '',
        'cwd': fg?['cwd'] ?? t['cwd'] ?? '',
        'agent_status': _statusOf(t),
      }));
      final status = t['status'];
      if (status is Map) {
        final app = '${status['app'] ?? fg?['name'] ?? ''}';
        final name = app.split('-').first;
        agents.add(AgentModel.fromJson({
          'agent': name,
          'usage': _conns[parentOf(m) ?? m]?.usage[name]?['usage'],
          'pane_id': address,
          'status': _statusOf(t),
          'completion_seq': t['turn'],
          'state_change_seq': t['status_ms'],
        }));
      }
    }

    String worst(Iterable<PaneModel> ps) =>
        urgency.firstWhere((s) => ps.any((p) => p.agentStatus == s), orElse: () => 'unknown');

    final placed = <String>{};
    for (final (i, Map space) in ((c.layout?['spaces'] as List?) ?? const []).indexed) {
      final from = panes.length;
      for (final (j, Map tab) in ((space['tabs'] as List?) ?? const []).indexed) {
        final start = panes.length;
        for (final address in _terminalsIn(tab['root'])) {
          if (!live.containsKey(address) || !placed.add(address)) continue;
          add(address, space['id'], tab['id']);
        }
        tabs.add(TabModel(
            id: tab['id'],
            workspaceId: space['id'],
            number: j + 1,
            label: tab['name'] ?? '',
            agentStatus: worst(panes.sublist(start))));
      }
      final own = panes.sublist(from);
      final first = own.isEmpty ? null : live[own.first.id];
      workspaces.add(WorkspaceModel(
        id: space['id'],
        number: i + 1,
        name: space['name'] as String? ?? '',
        label: (space['name'] as String?)?.isNotEmpty == true
            ? space['name']
            : _placeName('${(first?['foreground'] as Map?)?['cwd'] ?? first?['cwd'] ?? space['folder'] ?? ''}'),
        agentStatus: worst(own),
      ));
    }
    for (final address in live.keys) {
      if (!placed.contains(address) && live[address]!['status'] is Map) add(address, '', '');
    }
    _apply(m, SessionSnapshot(workspaces: workspaces, tabs: tabs, panes: panes, agents: agents));
  }

  /// Rereads [root]'s usage from the herdr-usage mod, if it has one there.
  Future<void> _fetchUsage(String root) async {
    final link = _conns[root]?.link;
    if (link == null) return;
    try {
      final res = await link.call('file.read', {'path': '.config/herdr-app/shared.json'}) as Map;
      final usage = (jsonDecode(res['text']) as Map)['herdr-usage.v1'];
      if (usage is! Map) return;
      _conns[root]!.usage = usage;
      for (final m in [root, ..._machines.where((x) => parentOf(x) == root)]) {
        _rebuild(m);
      }
    } catch (_) {}
  }

  /// A terminal's status in the app's words: herdr-core's own, with `error` as needing you, and `idle`
  /// after a turn not yet viewed (its `herdr.seen` label, which Herdr keeps) as `done`, as Herdr shows it.
  static String _statusOf(Map t) {
    final state = (t['status'] as Map?)?['state'];
    if (state == 'idle' && t['turn'] is int) {
      final seen = int.tryParse('${(t['labels'] as Map?)?['herdr.seen']}');
      if (seen != null && t['turn'] > seen) return 'done';
    }
    return state == null ? 'unknown' : (state == 'error' ? 'blocked' : '$state');
  }

  /// Marks [paneId]'s last turn viewed (`herdr.seen`), as Herdr does for the terminal on screen.
  void _markSeen(String m, String paneId) {
    final t = _conns[m]?.terminals[paneId];
    final link = linkOf(m);
    if (t == null || link == null || t['turn'] is! int) return;
    final labels = t['labels'] = Map.of(t['labels'] as Map? ?? const {});
    if (labels['herdr.seen'] == '${t['turn']}') return;
    labels['herdr.seen'] = '${t['turn']}';
    link.call('terminal.label', {'terminal': addressOf(m, paneId), 'labels': {'herdr.seen': '${t['turn']}'}}).catchError((_) {});
  }

  /// The terminals of a layout node's blocks, in order.
  static Iterable<String> _terminalsIn(Object? node) sync* {
    if (node is! Map) return;
    if (node['content']?['terminal'] case final String t) yield t;
    for (final child in (node['children'] as List?) ?? const []) {
      yield* _terminalsIn(child);
    }
  }

  /// What the Herdr app calls a space with no name: after where its first terminal is, `~` at home.
  static String _placeName(String path) {
    if (path.isEmpty) return '';
    if (RegExp(r'^(/home/[^/]+|/Users/[^/]+|/root)/?$').hasMatch(path)) return '~';
    return path.split('/').where((s) => s.isNotEmpty).lastOrNull ?? '/';
  }

  /// Reports failed requests; set by the app, which shows them as a SnackBar on any screen.
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
    SharedPreferences.getInstance().then((p) => p.setString('hc_active', m));
  }

  /// Shows [m] (an SSH target, or a machine another one's core reaches), remembering it in the machine list
  /// and, with [connect], connecting it if it was off.
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
    _machines = machines.where(isValidMachine).toList();
    _names = _pairs(names)..removeWhere((k, _) => !isValidMachine(k));
    _off = off.where(isValidMachine).toSet();
    if (!_machines.contains(_machine)) _machine = _machines.firstOrNull ?? '';
    notifyListeners();
  }

  /// `key=value` entries, as stored in prefs.
  static Map<String, String> _pairs(List<String> entries) => {
        for (final n in entries)
          if (n.contains('=')) n.substring(0, n.indexOf('=')): n.substring(n.indexOf('=') + 1)
      };

  void removeMachine(String m) {
    _forget([m, ..._machines.where((x) => parentOf(x) == m)]);
    if (_machines.contains(machine)) return notifyListeners();
    if (_machines.isNotEmpty) return switchMachine(_machines.first);
    _machine = '';
    SharedPreferences.getInstance().then((p) => p.remove('hc_active'));
    notifyListeners();
  }

  void _forget(Iterable<String> gone) {
    if (gone.isEmpty) return;
    for (final m in gone) {
      _close(m);
      _conns.remove(m);
    }
    _machines = _machines.where((x) => !gone.contains(x)).toList();
    _names = {..._names}..removeWhere((k, _) => gone.contains(k));
    _off = _off.difference(gone.toSet());
    _saveMachines();
  }

  /// Adds [target] (`user@host`, or a host from the SSH config there) to [root]'s herdr-core, which then
  /// reaches it like its other machines. False on failure, reported to [onError].
  Future<bool> addSshMachine(String root, String target, String name) async {
    final ok = await _core('add $target', root, 'machine.add', {'target': target, if (name.isNotEmpty) 'name': name});
    await _discover(root);
    return ok != null;
  }

  /// Renames [m], a machine another one's core reaches, there, and given another [target], adds it anew
  /// under its name, since herdr-core can't change a target. False on failure, reported to [onError].
  Future<bool> editSshMachine(String m, String target, String name) async {
    final root = parentOf(m)!;
    final old = m.substring(m.lastIndexOf('/') + 1);
    final newName = name.isEmpty ? old : name;
    if (target != _targets[m]) {
      if (await _core('change ${nameOf(m)}', root, 'machine.rm', {'machine': old}) == null) return false;
      final ok = await _core('change ${nameOf(m)}', root, 'machine.add', {'target': target, 'name': newName});
      await _discover(root);
      return ok != null;
    }
    if (newName != old && await _core('rename ${nameOf(m)}', root, 'machine.rename', {'machine': old, 'new_name': newName}) == null) {
      return false;
    }
    await _discover(root);
    return true;
  }

  /// Removes [m], a machine another one's core reaches, from that core, which is where it comes from.
  Future<void> removeSshMachine(String m) async {
    final root = parentOf(m)!;
    await _core('remove ${nameOf(m)}', root, 'machine.rm', {'machine': m.substring(m.lastIndexOf('/') + 1)});
    await _discover(root);
  }

  /// One herdr-core call on [m]'s link; failures go to [onError] as "Could not [what]", and give null.
  Future<dynamic> _core(String what, String m, String method, Map<String, dynamic> params) async {
    final link = _route(m).$1;
    try {
      if (link == null) throw HcError('unavailable', '${nameOf(parentOf(m) ?? m)} is not connected');
      return await link.call(method, params) ?? true;
    } catch (e) {
      debugPrint('$method on $m failed: $e');
      onError?.call('Could not $what: $e');
      return null;
    }
  }

  /// Renames [m] and/or moves it to [to] (another SSH target), keeping its place in the list and its on/off
  /// state. The machines its core reaches are found again at the new address.
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

  /// Puts the machines [m]'s core reaches (`hc machine ls` there) right after it, named as there, and
  /// forgets the ones it no longer does.
  Future<void> _discover(String m) async {
    final link = _conns[m]?.link;
    if (parentOf(m) != null || link == null) return;
    try {
      final res = await link.call('machine.list') as Map;
      _applyDiscovered(m, res['machines'] as List);
    } catch (_) {}
  }

  void _applyDiscovered(String m, List found) {
    if (parentOf(m) != null || !_machines.contains(m)) return;
    final children = {for (final f in found) '$m/m/${f['name']}': '${f['name']}'};
    final newTargets = {for (final f in found) '$m/m/${f['name']}': '${f['target'] ?? ''}'};
    for (final f in found) {
      final c = _conns.putIfAbsent('$m/m/${f['name']}', _Conn.new);
      final up = f['state'] == 'connected' && isConnected(m);
      if (c.connected != up) {
        c.connected = up;
        if (up) _fetchLayout('$m/m/${f['name']}');
      }
      c.failure = up ? null : (f['why'] as String?) ?? '${f['name']} is ${'${f['state']}'.replaceAll('_', ' ')}';
    }
    final removed = _machines.where((x) => parentOf(x) == m && !children.containsKey(x)).toList();
    final kept = _machines.where((x) => parentOf(x) == m && children.containsKey(x)).toList();
    final added = children.keys.where((x) => !_machines.contains(x)).toList();
    final namesChanged = children.entries.any((e) => _names[e.key] != e.value);
    final targetsChanged = newTargets.entries.any((e) => _targets[e.key] != e.value);
    if (removed.isEmpty && added.isEmpty && !namesChanged && !targetsChanged) return notifyListeners();
    if (removed.isNotEmpty) {
      _forget(removed);
      _targets = {..._targets}..removeWhere((k, _) => removed.contains(k));
    }
    _targets = {..._targets, ...newTargets};
    if (!_machines.contains(machine)) _setActive(m);
    final i = _machines.indexOf(m);
    if (added.isNotEmpty) {
      _machines = [..._machines.sublist(0, i + 1 + kept.length), ...added, ..._machines.sublist(i + 1 + kept.length)];
    }
    _names = {..._names, for (final e in children.entries) e.key: e.value};
    _saveMachines();
    for (final x in added) {
      _rebuild(x);
    }
    notifyListeners();
  }

  /// Rereads the machines every connected core reaches.
  Future<void> discoverMachines() async {
    final roots = _machines.where((x) => parentOf(x) == null && isConnected(x)).toList();
    for (final r in roots) {
      await _discover(r);
    }
  }

  Timer? _discoveryTimer;
  int _ticks = 0;

  void _startDiscoveryTimer() {
    if (!_started || _disposed) return;
    _discoveryTimer?.cancel();
    _discoveryTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      if (!_started || _disposed) return;
      if (WidgetsBinding.instance.lifecycleState != null &&
          WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
        return;
      }
      discoverMachines();
      // Usage moves slowly, and the mod itself reads it every minute or two.
      if (++_ticks % 6 == 0) {
        for (final r in _machines.where((x) => parentOf(x) == null && isConnected(x))) {
          _fetchUsage(r);
        }
      }
    });
  }

  void _stopDiscoveryTimer() {
    _discoveryTimer?.cancel();
    _discoveryTimer = null;
  }

  void _saveMachines() => SharedPreferences.getInstance().then((p) => p
    ..setStringList('hc_machines', _machines)
    ..setStringList('hc_machine_names', [for (final e in _names.entries) '${e.key}=${e.value}'])
    ..setStringList('hc_machines_off', _off.toList()));

  /// Shows [machine] (as stored in [machines]) as it is: one the user disconnected stays off. The others
  /// stay as they are.
  void switchMachine(String machine) => configure(machine, connect: false);

  void selectPane(String paneId) {
    _conns.putIfAbsent(machine, _Conn.new).selectedPaneId = paneId;
    _markSeen(machine, paneId);
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
    int rank(AgentModel a) => switch (urgency.indexOf(a.status)) { -1 => urgency.length, final i => i };
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

  void _apply(String m, SessionSnapshot snapshot) {
    final c = _conns.putIfAbsent(m, _Conn.new);
    final before = c.raw;
    c.raw = snapshot;
    _show(m);
    // After a dropout [before] is the last snapshot seen, so what changed meanwhile still alerts.
    if (before != null && _alerts) _alertChanges(m, before, snapshot);
    // A pane gone mustn't leave its completion count, nor its mute, to a later one.
    c.completions.removeWhere((id, _) => !snapshot.panes.any((p) => p.id == id));
    // Until the layout is in, tabbed panes without a running agent are missing, not gone.
    if (c.layout == null) return notifyListeners();
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
    // Agents outside any tab (sub-agents, `hc run`) stay: only a hidden tab hides its panes.
    final panes = s.panes.where((p) => !hidden(p.id) && (p.tabId.isEmpty || tabs.any((t) => t.id == p.tabId))).toList();
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
    if (now.panes.isEmpty) return null;
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
      // A turn also ends when the agent stops to ask: that's the needs-you alert, not a second one.
      final finished = wasAgent != null && seq > seen && agent?.status != 'blocked' && pane.agentStatus != 'blocked';
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

  /// Runs a Herdr app command on the machine whose window shows [on]'s spaces (the machine the phone
  /// dials: its window shows the machines its core reaches too), through herdr-core. Spaces and tabs are
  /// the app's, so changing them needs its window open there. Failures go to [onError] as "Could not
  /// [what]"; gives the command's answer, or null on failure.
  Future<dynamic> _app(String what, String command, Map<String, dynamic> args, {String? on, bool report = true}) async {
    final m = on ?? machine;
    final root = parentOf(m) ?? m;
    // The window names a reached machine's spaces, tabs and panes `<machine>/<id>`.
    if (parentOf(m) != null) {
      final prefix = '${m.substring(m.lastIndexOf('/') + 1)}/';
      args = {
        for (final e in args.entries)
          e.key: const {'id', 'space', 'pane'}.contains(e.key) && e.value is String ? '$prefix${e.value}' : e.value,
      };
    }
    try {
      final link = _conns[root]?.link;
      if (link == null) throw '${nameOf(root)} is not connected';
      final Map res;
      try {
        res = await link.call('machine.exec', {
        'argv': ['herdr-app', 'do', command, jsonEncode(args)],
        'timeout': 20,
        }) as Map;
      } on HcError catch (e) {
        // Run without a shell, a missing program fails to start rather than exiting 127.
        if (e.kind == 'spawn_failed') throw "Herdr isn't installed on ${nameOf(root)}";
        rethrow;
      }
      final out = utf8.decode(base64.decode(res['stdout'] ?? ''), allowMalformed: true).trim();
      final err = utf8.decode(base64.decode(res['stderr'] ?? ''), allowMalformed: true).trim();
      if (res['code'] != 0) {
        if (err.contains('no Herdr window')) throw 'open Herdr on ${nameOf(root)} to change its spaces';
        throw _parseError(out.isNotEmpty ? out : err);
      }
      try {
        return out.isEmpty ? true : jsonDecode(out);
      } on FormatException {
        return true;
      }
    } catch (e) {
      debugPrint('herdr-app do $command on $root failed: $e');
      if (report) onError?.call('Could not $what: $e');
      return null;
    }
  }

  String _parseError(dynamic e) {
    try {
      final text = e.toString();
      final data = jsonDecode(text.substring(text.indexOf('{')));
      if (data is Map && data['error'] != null) return data['error'].toString();
      if (data is Map && data['message'] != null) return data['message'].toString();
    } catch (_) {}
    return e.toString();
  }

  Future<void> createTab(String workspaceId) async =>
      _openCreated(machine, await _app('create tab', 'tab.new', {'space': workspaceId, 'focus': false}));

  /// Shows the terminal a `tab.new` or `space.new` on [m] made, unless another machine is on screen now.
  void _openCreated(String m, Object? res) {
    final t = res is Map ? res['terminal'] : null;
    if (t is String && m == machine) selectPane(t.substring(t.lastIndexOf('/') + 1));
  }

  /// Puts image [bytes] beside the selected terminal, on its machine, for its agent to read. Returns the
  /// path for `@`-references, or null (already reported to [onError]).
  Future<String?> uploadImage(List<int> bytes, String mime) async {
    final pane = selectedPaneId;
    if (pane == null) return null;
    final (_, prefix) = _route(machine);
    final res = await _core('attach image', machine, 'terminal.put', {
      'terminal': '$prefix$pane',
      'name': 'image.${mime.split('/').last.replaceAll('jpeg', 'jpg')}',
      'data': base64Encode(bytes),
    });
    return res is Map ? res['path'] as String? : null;
  }

  Future<void> closeTab(String tabId, [String? m]) =>
      _app('close tab', 'tab.close', {'id': tabId, 'confirmed': true}, on: m);

  /// Closes [paneId] on [m] (the active machine by default): its pane in the Herdr app when it has one,
  /// which ends its terminal; else (a sub-agent, an `hc run`) just ends the terminal.
  Future<void> closePane(String paneId, [String? m]) async {
    final on = m ?? machine;
    final c = _conns[on];
    final inTab = c?.raw?.panes.any((p) => p.id == paneId && p.tabId.isNotEmpty) ?? false;
    c?.raw?.panes.removeWhere((p) => p.id == paneId);
    c?.raw?.agents.removeWhere((a) => a.paneId == paneId);
    final block = inTab ? _blockOf(c!.layout, paneId) : null;
    // Without the Herdr window open its pane can't be closed: end the terminal instead.
    if (block == null || await _app('close agent', 'pane.close', {'pane': block}, on: on, report: false) == null) {
      await _core('close agent', on, 'terminal.kill', {'terminal': '${_route(on).$2}$paneId'});
    }
    _rebuild(on);
  }

  /// The id of the layout block showing [terminal].
  static String? _blockOf(Map? layout, String terminal) {
    String? find(Object? node) {
      if (node is! Map) return null;
      if (node['content']?['terminal'] == terminal) return node['id'];
      for (final child in (node['children'] as List?) ?? const []) {
        if (find(child) case final id?) return id;
      }
      return null;
    }

    for (final Map space in (layout?['spaces'] as List?) ?? const []) {
      for (final Map tab in (space['tabs'] as List?) ?? const []) {
        if (find(tab['root']) case final id?) return id;
      }
    }
    return null;
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
    await _app('move tab', 'tab.move', {'id': tabId, 'index': to + 1});
  }

  /// A new space on the active machine, in its home.
  Future<void> createWorkspace() async {
    final m = machine;
    _openCreated(
        m,
        await _app('create workspace', 'space.new', {
          'machine': parentOf(m) == null ? '' : m.substring(m.lastIndexOf('/') + 1),
          'focus': false,
        }));
  }

  /// Closes a space and ends its terminals.
  Future<void> deleteWorkspace(String workspaceId, {String? on}) =>
      _app('close workspace', 'space.close', {'id': workspaceId, 'confirmed': true}, on: on);

  Future<void> renameWorkspace(String workspaceId, String label, {String? on}) =>
      _app('rename workspace', 'space.rename', {'id': workspaceId, 'name': label}, on: on);

  /// Moves [ids] (a workspace) before [beforeId], or to the end when null. Reorders the local snapshot
  /// first so the list doesn't jump back while the request runs.
  Future<void> moveWorkspaces(List<String> ids, String? beforeId) async {
    final list = snapshot?.workspaces;
    if (list == null) return;
    final moved = list.where((w) => ids.contains(w.id)).toList();
    list.removeWhere((w) => ids.contains(w.id));
    final at = list.indexWhere((w) => w.id == beforeId);
    list.insertAll(at < 0 ? list.length : at, moved);
    notifyListeners();
    for (final w in moved) {
      await _app('move workspace', 'space.move', {'id': w.id, 'index': list.indexOf(w) + 1});
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

  @override
  void dispose() {
    _disposed = true;
    _stopDiscoveryTimer();
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
