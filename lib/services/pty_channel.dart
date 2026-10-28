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

  /// Called with the `term-closed` reason the bridge sends when herdr ends the
  /// session (e.g. another client holds the pane), before the reconnect logic.
  final ValueChanged<String>? onClose;

  /// One-shot request to steal the pane from another attached client
  /// (`?takeover=1`): used for the next attach only, so a held pane is taken
  /// over when the user asks, never by background reconnects fighting it.
  final bool takeover;

  /// Whether herdr is streaming the pane: set by each attach's first frame, cleared when the connection drops.
  final attached = ValueNotifier(false);

  WebSocketChannel? _channel; // null between a dropped connection and the next attempt
  StreamSubscription? _sub;
  Timer? _reconnectTimer;
  int _fails = 0; // attempts in a row that never attached, to back off
  bool _takeoverArmed; // a steal asked for this channel, spent on its first attach
  String? _closeReason; // why herdr ended the last session, when it said
  final _pending = <String>[]; // input typed while there was no connection, sent with the next one
  bool _disposed = false;
  final _held = StringBuffer();
  bool _hold = false;

  /// Whether herdr refused the attach because another client holds the pane
  /// ("already has an attached client"), or this client was taken over by one
  /// ("terminal attach taken over"): then a fast reconnect would only fight it.
  static bool isBusyReason(String reason) =>
      reason.contains('already has an attached client') || reason.contains('taken over');

  /// How long a reconnect waits: 15 s after herdr reported a busy pane, else
  /// soon, since on a phone most drops are brief, backing off while it fails.
  Duration get _retryDelay => _closeReason != null && isBusyReason(_closeReason!)
      ? const Duration(seconds: 15)
      : Duration(milliseconds: 500 << _fails.clamp(0, 3));

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
    this.onClose,
    this.takeover = false,
  }) : _takeoverArmed = takeover;

  void connect() {
    if (_disposed) return;
    // Herdr sends rendered frames of its own viewport (absolute cursor moves, no newlines), so the
    // pane's history lives in herdr, not here. Keep xterm on the alt screen, which has no scrollback,
    // and start each attach from a blank screen; herdr repaints the whole pane on attach. The clear goes
    // in front of the first frame, not here, so the old screen stays up until then instead of going black.
    var reset = '\x1b[?1049h\x1b[0m\x1b[H\x1b[2J';
    var closed = false; // herdr ended this session: the frames after it are its reason, not the pane
    final take = _takeoverArmed;
    _takeoverArmed = false;
    final uri = Uri.parse(
        'ws://$machine/ws/term/${Uri.encodeComponent(paneId)}?cols=${terminal.viewWidth}&rows=${terminal.viewHeight}${take ? '&takeover=1' : ''}');
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
    // Text frames carry the bridge's `term-closed` reasons; anything else is ignored.
    _sub = channel.stream.listen(
      (data) {
        if (data is String) {
          try {
            final msg = jsonDecode(data);
            if (msg is Map && msg['type'] == 'term-closed' && msg['reason'] is String) {
              _closeReason = msg['reason'] as String;
              closed = true;
              onClose?.call(_closeReason!);
            }
          } catch (_) {}
          return;
        }
        if (data is! List<int>) return;
        final text = const Utf8Decoder(allowMalformed: true).convert(data);
        _hold ? _held.write(reset + text) : terminal.write(reset + text);
        if (reset.isNotEmpty && !closed) {
          _reconnectTimer?.cancel();
          _fails = 0;
          _closeReason = null;
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

  /// Retries after [_retryDelay]: soon for a dropped connection, slowly when
  /// another client holds the pane, so the two never fight over it.
  /// The screen keeps the last frame meanwhile; [attached] tells it it's stale.
  void _dropped(WebSocketChannel channel) {
    if (_disposed || _channel != channel) return;
    _reconnectTimer?.cancel();
    _sub?.cancel();
    channel.sink.close();
    _channel = null;
    attached.value = false;
    _reconnectTimer = Timer(_retryDelay, connect);
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
  /// [column] and [row] are 0-based screen cells under the gesture: herdr hands an
  /// alternate-screen app the scroll as a mouse wheel there, so it reaches the widget
  /// being scrolled (OpenCode only scrolls the widget under the wheel, unlike Claude).
  void sendScroll(int lines, {int? column, int? row}) {
    _channel?.sink.add(jsonEncode({
      'type': 'terminal.scroll',
      'direction': lines > 0 ? 'up' : 'down',
      'lines': lines.abs(),
      if (column != null) 'column': column,
      if (row != null) 'row': row,
    }));
  }

  /// A left click on a cell (0-based), which herdr hands to the pane only if its program asked for the mouse.
  void sendClick(int column, int row) {
    for (final action in ['down', 'up']) {
      _channel?.sink.add(
          jsonEncode({'type': 'terminal.mouse', 'action': action, 'button': 'left', 'column': column, 'row': row}));
    }
  }

  void dispose() {
    _disposed = true;
    _reconnectTimer?.cancel();
    _sub?.cancel();
    _channel?.sink.close();
    attached.dispose();
  }
}
