import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:xterm/xterm.dart';

class PtyChannel {
  final String host;
  final int port;
  final String paneId;
  final Terminal terminal;

  WebSocketChannel? _channel;
  StreamSubscription? _sub;
  bool _disposed = false;

  PtyChannel({
    required this.host,
    required this.port,
    required this.paneId,
    required this.terminal,
  });

  void connect() {
    if (_disposed) return;
    _channel?.sink.close();

    final uri = Uri.parse('ws://$host:$port/ws/pane/$paneId');
    try {
      _channel = WebSocketChannel.connect(uri);
      _sub = _channel!.stream.listen(
        (data) {
          if (data is String) {
            terminal.write(data);
          } else if (data is List<int>) {
            terminal.write(utf8.decode(data, allowMalformed: true));
          }
        },
        onError: (err) {
          debugPrint('PTY WS error for pane $paneId: $err');
        },
        onDone: () {
          debugPrint('PTY WS closed for pane $paneId');
        },
      );
    } catch (e) {
      debugPrint('Failed to connect PTY channel: $e');
    }
  }

  void sendInput(String input) {
    if (_channel != null) {
      _channel!.sink.add(jsonEncode({
        'type': 'input',
        'text': input,
      }));
    }
  }

  void sendKey(String key) {
    if (_channel != null) {
      _channel!.sink.add(jsonEncode({
        'type': 'input',
        'keys': [key],
      }));
    }
  }

  void sendResize(int cols, int rows) {
    if (_channel != null) {
      _channel!.sink.add(jsonEncode({
        'type': 'resize',
        'cols': cols,
        'rows': rows,
      }));
    }
  }

  void dispose() {
    _disposed = true;
    _sub?.cancel();
    _channel?.sink.close();
  }
}
