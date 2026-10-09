import 'dart:async';
import 'dart:convert';
import 'dart:io';
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

  /// Whether herdr is streaming the pane: set by each attach's first frame, cleared when the connection drops.
  final attached = ValueNotifier(false);

  WebSocketChannel? _channel; // null between a dropped connection and the next attempt
  StreamSubscription? _sub;
  Timer? _reconnectTimer;
  int _fails = 0; // attempts in a row that never attached, to back off
  final _pending = <String>[]; // input typed while there was no connection, sent with the next one
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
    // Pings notice a connection that died silently (a bad signal, a changed network), which would otherwise
    // freeze the screen and swallow input until TCP gives up, minutes later. Only a pong counts, and on a
    // congested link it waits behind the frames, so shorter would drop slow but live connections; longer
    // also lets the phone's radio rest between them.
    final channel = IOWebSocketChannel(
        WebSocket.connect(uri.toString(), headers: headers).then((s) => s..pingInterval = const Duration(seconds: 10)));
    _channel = channel;
    // An attempt made while the network is down can hang as long, so one not streaming soon is given up
    // (soon enough for a slow link, or a machine the bridge reaches over SSH).
    _reconnectTimer = Timer(const Duration(seconds: 20), () => _dropped(channel));
    // Connection failures also reach the stream's onError, which reconnects.
    channel.ready.ignore();
    // The sink holds them until the socket opens.
    for (final input in _pending) {
      channel.sink.add(utf8.encode(input));
    }
    _pending.clear();
    // Utf8Decoder as a stream transformer keeps multi-byte characters split across frames intact.
    _sub = channel.stream
        .where((data) => data is List<int>)
        .cast<List<int>>()
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen(
      (data) {
        _hold ? _held.write(reset + data) : terminal.write(reset + data);
        if (reset.isNotEmpty) {
          _reconnectTimer?.cancel();
          _fails = 0;
          attached.value = true;
          onAttach?.call();
        }
        reset = '';
      },
      onError: (err) {
        debugPrint('Terminal WS error: $err');
        _dropped(channel);
      },
      onDone: () => _dropped(channel),
      cancelOnError: true,
    );
  }

  /// Retries soon, since on a phone most drops are brief, backing off to every 4 s while it keeps failing.
  /// The screen keeps the last frame meanwhile; [attached] tells it it's stale.
  void _dropped(WebSocketChannel channel) {
    if (_disposed || _channel != channel) return;
    _reconnectTimer?.cancel();
    _sub?.cancel();
    channel.sink.close();
    _channel = null;
    attached.value = false;
    _reconnectTimer = Timer(Duration(milliseconds: 500 << _fails.clamp(0, 3)), connect);
    _fails++;
  }

  /// Input typed while reconnecting waits for the connection rather than vanishing.
  void sendInput(String input) {
    final channel = _channel;
    channel == null ? _pending.add(input) : channel.sink.add(utf8.encode(input));
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
    attached.dispose();
  }
}
