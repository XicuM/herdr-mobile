import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:xterm/xterm.dart';

/// Streams one herdr pane, sized to this terminal, through the bridge.
/// Binary frames carry terminal bytes both ways; text frames carry resize control.
class PtyChannel {
  final String host;
  final int port;
  final String paneId;
  final Terminal terminal;

  WebSocketChannel? _channel;
  StreamSubscription? _sub;
  Timer? _reconnectTimer;
  bool _disposed = false;

  PtyChannel({
    required this.host,
    required this.port,
    required this.paneId,
    required this.terminal,
  });

  void connect() {
    if (_disposed) return;
    final uri = Uri.parse(
        'ws://$host:$port/ws/term/${Uri.encodeComponent(paneId)}?cols=${terminal.viewWidth}&rows=${terminal.viewHeight}');
    _channel = WebSocketChannel.connect(uri);
    // Utf8Decoder as a stream transformer keeps multi-byte characters split across frames intact.
    _sub = _channel!.stream
        .where((data) => data is List<int>)
        .cast<List<int>>()
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen(
          terminal.write,
          onError: (err) {
            debugPrint('Terminal WS error: $err');
            _scheduleReconnect();
          },
          onDone: _scheduleReconnect,
          cancelOnError: true,
        );
  }

  void _scheduleReconnect() {
    if (_disposed) return;
    _reconnectTimer = Timer(const Duration(seconds: 2), connect);
  }

  void sendInput(String input) {
    _channel?.sink.add(utf8.encode(input));
  }

  void sendResize(int cols, int rows) {
    _channel?.sink.add(jsonEncode({'cols': cols, 'rows': rows}));
  }

  void dispose() {
    _disposed = true;
    _reconnectTimer?.cancel();
    _sub?.cancel();
    _channel?.sink.close();
  }
}
