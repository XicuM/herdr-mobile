import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:xterm/xterm.dart';

/// Streams one herdr pane, sized to this terminal, through the bridge.
/// Binary frames carry terminal bytes both ways; text frames carry resizes and scrolls.
class PtyChannel {
  /// As in [HerdrClientService.machines]: `host:port`, or a machine its bridge reaches.
  final String machine;
  final String paneId;
  final Terminal terminal;

  /// The bridge's token header ([HerdrClientService.headersOf]).
  final Map<String, String> headers;

  /// Called with each attach's first frame, when herdr shows the pane live.
  final VoidCallback? onAttach;

  WebSocketChannel? _channel;
  StreamSubscription? _sub;
  Timer? _reconnectTimer;
  bool _disposed = false;
  final _held = StringBuffer();
  bool _hold = false;

  /// While set (text is selected), frames wait instead of moving the text under the selection; cleared,
  /// they're written in order.
  set hold(bool value) {
    if (_hold == value) return;
    _hold = value;
    if (value || _held.isEmpty) return;
    terminal.write(_held.toString());
    _held.clear();
  }

  PtyChannel({
    required this.machine,
    required this.paneId,
    required this.terminal,
    this.headers = const {},
    this.onAttach,
  });

  void connect() {
    if (_disposed) return;
    // Herdr sends rendered frames of its own viewport (absolute cursor moves, no newlines), so the
    // pane's history lives in herdr, not here. Keep xterm on the alt screen, which has no scrollback,
    // and start each attach from a blank screen; herdr repaints the whole pane on attach. The clear goes
    // in front of the first frame, not here, so the old screen stays up until then instead of going black.
    var reset = '\x1b[?1049h\x1b[0m\x1b[H\x1b[2J';
    final uri = Uri.parse(
        'ws://$machine/ws/term/${Uri.encodeComponent(paneId)}?cols=${terminal.viewWidth}&rows=${terminal.viewHeight}');
    _channel = IOWebSocketChannel.connect(uri, headers: headers);
    // Connection failures also reach the stream's onError, which reconnects.
    _channel!.ready.ignore();
    // Utf8Decoder as a stream transformer keeps multi-byte characters split across frames intact.
    _sub = _channel!.stream
        .where((data) => data is List<int>)
        .cast<List<int>>()
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen(
      (data) {
        _hold ? _held.write(reset + data) : terminal.write(reset + data);
        if (reset.isNotEmpty) onAttach?.call();
        reset = '';
      },
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

  /// Scrolls herdr's view of the pane through its history; positive [lines] go back in time.
  void sendScroll(int lines) {
    _channel?.sink
        .add(jsonEncode({'type': 'terminal.scroll', 'direction': lines > 0 ? 'up' : 'down', 'lines': lines.abs()}));
  }

  void dispose() {
    _disposed = true;
    _reconnectTimer?.cancel();
    _sub?.cancel();
    _channel?.sink.close();
  }
}
