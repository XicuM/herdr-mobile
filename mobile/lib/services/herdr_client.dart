import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../models/session.dart';

class HerdrClientService extends ChangeNotifier {
  String _host = '127.0.0.1';
  int _port = 7788;
  bool _connected = false;
  SessionSnapshot? _snapshot;
  String? _selectedPaneId;
  double _fontSize = 14;
  List<String> _machines = [];

  WebSocketChannel? _channel;
  Timer? _reconnectTimer;
  bool _disposed = false;

  String get host => _host;
  int get port => _port;
  bool get connected => _connected;
  SessionSnapshot? get snapshot => _snapshot;
  String? get selectedPaneId => _selectedPaneId;
  double get fontSize => _fontSize;
  String get machine => '$_host:$_port';

  /// Saved bridges as `host:port`, one per machine running herdr-bridge.
  List<String> get machines => _machines;

  static const double minFontSize = 6;
  static const double maxFontSize = 32;

  void setFontSize(double size) {
    final clamped = size.clamp(minFontSize, maxFontSize).toDouble();
    if (clamped == _fontSize) return;
    _fontSize = clamped;
    notifyListeners();
    SharedPreferences.getInstance().then((p) => p.setDouble('terminal_font_size', clamped));
  }

  /// Switches to the bridge at [host]:[port], remembering it in the machine list.
  void configure({required String host, required int port}) {
    final changed = host != _host || port != _port;
    _host = host;
    _port = port;
    if (!_machines.contains(machine)) _machines = [..._machines, machine];
    if (changed) {
      _snapshot = null;
      _selectedPaneId = null;
    }
    SharedPreferences.getInstance().then((p) => p
      ..setString('herdr_host', host)
      ..setInt('herdr_port', port)
      ..setStringList('herdr_machines', _machines));
    reconnect();
  }

  void setMachines(List<String> machines) {
    _machines = machines;
    notifyListeners();
    SharedPreferences.getInstance().then((p) => p.setStringList('herdr_machines', machines));
  }

  /// [machine] is `host:port` as stored in [machines].
  void switchMachine(String machine) {
    final i = machine.lastIndexOf(':');
    configure(host: machine.substring(0, i), port: int.parse(machine.substring(i + 1)));
  }

  void selectPane(String paneId) {
    _selectedPaneId = paneId;
    notifyListeners();
  }

  void connect() {
    if (_disposed) return;
    _reconnectTimer?.cancel();

    final wsUri = Uri.parse('ws://$_host:$_port/ws/session');
    try {
      final channel = WebSocketChannel.connect(wsUri);
      _channel = channel;
      // Connection failures also reach the stream's onError, which reconnects.
      channel.ready.ignore();
      // Ignore a replaced socket's late frames so they can't leak into another machine's state.
      channel.stream.listen(
        (message) {
          if (channel != _channel) return;
          if (!_connected) {
            _connected = true;
            notifyListeners();
          }
          _handleMessage(message);
        },
        onError: (error) {
          if (channel == _channel) _handleDisconnect();
        },
        onDone: () {
          if (channel == _channel) _handleDisconnect();
        },
      );
    } catch (e) {
      _handleDisconnect();
    }
  }

  void _handleMessage(dynamic message) {
    try {
      final data = jsonDecode(message.toString());
      final type = data['type'];

      if (type == 'snapshot') {
        _applySnapshot(SessionSnapshot.fromJson(data['data']));
      } else if (type == 'event') {
        // Refetch snapshot on topology or status change
        _fetchSnapshotHttp();
      }
    } catch (e) {
      debugPrint('Error parsing session WS message: $e');
    }
  }

  void _applySnapshot(SessionSnapshot snapshot) {
    _snapshot = snapshot;
    _selectedPaneId ??= snapshot.focusedPaneId ?? snapshot.panes.firstOrNull?.id;
    notifyListeners();
  }

  Future<void> _fetchSnapshotHttp() async {
    final from = machine;
    try {
      final res = await http.get(Uri.parse('http://$from/api/snapshot'));
      if (res.statusCode == 200 && from == machine) {
        final data = jsonDecode(res.body);
        _applySnapshot(SessionSnapshot.fromJson(data));
      }
    } catch (_) {}
  }

  void _handleDisconnect() {
    if (_connected) {
      _connected = false;
      notifyListeners();
    }
    _channel = null;
    _reconnectTimer?.cancel();
    if (!_disposed) {
      _reconnectTimer = Timer(const Duration(seconds: 3), () {
        connect();
      });
    }
  }

  void reconnect() {
    final old = _channel;
    _channel = null;
    old?.sink.close();
    _connected = false;
    notifyListeners();
    connect();
  }

  Future<void> createTab(String workspaceId) => _create('tab', {'workspace_id': workspaceId});

  Future<void> createWorkspace() => _create('workspace', {});

  /// POSTs to the bridge's `/api/<kind>` create route, then selects the new root pane.
  Future<void> _create(String kind, Map<String, dynamic> params) async {
    try {
      final res = await http.post(
        Uri.parse('http://$_host:$_port/api/$kind'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(params),
      );
      final paneId = jsonDecode(res.body)['root_pane']?['pane_id'];
      await _fetchSnapshotHttp();
      if (paneId is String) selectPane(paneId);
    } catch (e) {
      debugPrint('Failed to create $kind: $e');
    }
  }

  Future<void> sendPaneInput(String paneId, {String? text, List<String>? keys}) async {
    try {
      await http.post(
        Uri.parse('http://$_host:$_port/api/pane/$paneId/input'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          if (text != null) 'text': text,
          if (keys != null) 'keys': keys,
        }),
      );
    } catch (e) {
      debugPrint('Failed to send input: $e');
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _reconnectTimer?.cancel();
    _channel?.sink.close();
    super.dispose();
  }
}
