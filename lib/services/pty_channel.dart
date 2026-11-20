import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:xterm/xterm.dart';
import 'hc.dart';

/// Streams one terminal from herdr-core into [terminal], sized to it: `terminal.attach` on the machine's
/// link, whose channel carries a first paint (screen, some history, modes), then the program's raw output;
/// keys go back as DATA on it, and size as RESIZE. Attaching makes this phone the terminal's active viewer,
/// so the terminal takes its size until another viewer (the desktop) types, resizes or gains focus.
class PtyChannel {
  /// As in [HerdrClientService.machines].
  final String machine;
  final String paneId;
  final Terminal terminal;

  /// The link to reach it now (it changes when the machine reconnects), and its address through it.
  final HcLink? Function() link;
  final String address;

  /// Called with each attach's first frame.
  final VoidCallback? onAttach;

  /// Called with why herdr-core refused or ended the stream (the terminal finished), before retrying.
  final ValueChanged<String>? onClose;

  /// Whether the terminal is streaming: set by each attach's first frame, cleared when it drops.
  final attached = ValueNotifier(false);

  HcLink? _link;
  int? _channel;
  Timer? _retry;
  int _fails = 0; // attempts in a row that never attached, to back off
  final _pending = <int>[]; // input typed while there was no stream, sent with the next one
  bool _disposed = false;
  final _held = StringBuffer();
  bool _hold = false;

  /// While set (text is selected), output waits instead of moving the text under the selection; cleared,
  /// it's written in order.
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
    required this.link,
    required this.address,
    this.onAttach,
    this.onClose,
  });

  Future<void> connect() async {
    if (_disposed) return;
    final link = _link = this.link();
    if (link == null) return _dropped(null);
    try {
      final (cols, rows) = (terminal.viewWidth, terminal.viewHeight);
      final res = await link.call('terminal.attach', {
        'terminal': address,
        'cols': cols,
        'rows': rows,
        'history': 2000,
        // Back after a dropped line: the size is set only once the phone is active again.
        'resumed': _fails > 0,
      }) as Map;
      final channel = res['channel'] as int;
      if (_disposed || _link != link) {
        link.send(channel, HcLink.close, const []);
        return;
      }
      _channel = channel;
      // The view may have been laid out (or resized) while attaching: a resize meanwhile was dropped.
      if (terminal.viewWidth != cols || terminal.viewHeight != rows) sendResize(terminal.viewWidth, terminal.viewHeight);
      final decoder = const Utf8Decoder(allowMalformed: true).startChunkedConversion(_Sink(_write));
      var first = true;
      link.listen(channel, (kind, payload) {
        if (kind == HcLink.close) {
          if (payload.isNotEmpty) onClose?.call(_reason(payload));
          return _dropped(channel);
        }
        if (kind != HcLink.data) return;
        if (first) {
          // The first paint resets the modes and repaints the screen; this phone's own scrollback goes too,
          // since the paint brings the history again.
          first = false;
          terminal.useMainBuffer();
          terminal.mainBuffer.clearScrollback();
          _fails = 0;
          attached.value = true;
          // The paint resets with DECSTR (CSI ! p), which xterm ignores: reset what the last pane may have
          // left (hidden cursor, margins, wrap, insert/origin mode, line-drawing charset, keypad).
          terminal.write('\x1b[0m\x1b[?25h\x1b[?7h\x1b[?6l\x1b[4l\x1b[r\x1b(B\x1b)B\x0f\x1b>');
          decoder.add(payload);
          onAttach?.call();
        } else {
          decoder.add(payload);
        }
        link.send(channel, HcLink.credit, (ByteData(4)..setUint32(0, payload.length, Endian.little)).buffer.asUint8List());
      });
      if (_pending.isNotEmpty) {
        link.send(channel, HcLink.data, List.of(_pending));
        _pending.clear();
      }
      link.done.then((_) => _dropped(channel));
    } on HcError catch (e) {
      onClose?.call(e.message);
      _dropped(null);
    } catch (e) {
      debugPrint('Terminal attach failed: $e');
      _dropped(null);
    }
  }

  void _write(String text) => _hold ? _held.write(text) : terminal.write(text);

  static String _reason(Uint8List payload) {
    try {
      final r = jsonDecode(utf8.decode(payload));
      return r['reason'] == 'exited' ? 'It exited${r['exit_code'] == null ? '' : ' with ${r['exit_code']}'}' : '${r['reason']}';
    } catch (_) {
      return utf8.decode(payload, allowMalformed: true);
    }
  }

  /// Reattaches soon (a dropped line on a phone is usually brief), backing off while it fails. The screen
  /// keeps the last output meanwhile; [attached] tells it it's stale.
  void _dropped(int? channel) {
    if (_disposed || _channel != channel) return;
    if (channel != null) _link?.forget(channel);
    _channel = null;
    attached.value = false;
    _retry?.cancel();
    _retry = Timer(Duration(milliseconds: 500 << _fails.clamp(0, 4)), connect);
    _fails++;
  }

  /// Input typed while reconnecting waits for the stream rather than vanishing.
  void sendInput(String input) {
    final bytes = utf8.encode(input);
    final channel = _channel;
    channel == null ? _pending.addAll(bytes) : _link?.send(channel, HcLink.data, bytes);
  }

  void sendResize(int cols, int rows) {
    final channel = _channel;
    if (channel == null) return;
    _link?.send(channel, HcLink.resize,
        (ByteData(4)..setUint16(0, cols, Endian.little)..setUint16(2, rows, Endian.little)).buffer.asUint8List());
  }

  void dispose() {
    _disposed = true;
    _retry?.cancel();
    final channel = _channel;
    if (channel != null) {
      _link?.forget(channel);
      _link?.send(channel, HcLink.close, const []);
    }
    attached.dispose();
  }
}

class _Sink implements Sink<String> {
  _Sink(this._onText);
  final void Function(String) _onText;
  @override
  void add(String data) => _onText(data);
  @override
  void close() {}
}
