import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart';

/// The keys a phone keyboard can't type. CTRL is owned by the screen so it also applies to typed keys.
class KeyboardAccessoryBar extends StatefulWidget {
  final bool ctrl;
  final VoidCallback onCtrl;
  final void Function(TerminalKey key, {bool shift}) onKey;
  final void Function(String text) onText;

  const KeyboardAccessoryBar({
    super.key,
    required this.ctrl,
    required this.onCtrl,
    required this.onKey,
    required this.onText,
  });

  @override
  State<KeyboardAccessoryBar> createState() => _KeyboardAccessoryBarState();
}

class _KeyboardAccessoryBarState extends State<KeyboardAccessoryBar> {
  Timer? _repeat;

  @override
  void dispose() {
    _repeat?.cancel();
    super.dispose();
  }

  /// M3 tonal buttons, drawn small to fit nine in a row but each still a 48 dp tap target. CTRL turns
  /// filled while armed; ^C uses the error container. [repeat] keys fire again every 60 ms while held.
  Widget _key(String label, VoidCallback onTap, {bool repeat = false, bool active = false, bool danger = false}) {
    final scheme = Theme.of(context).colorScheme;
    final style = FilledButton.styleFrom(
      minimumSize: const Size(0, 34),
      padding: EdgeInsets.zero,
      textStyle: Theme.of(context).textTheme.labelMedium,
      backgroundColor: danger ? scheme.errorContainer : null,
      foregroundColor: danger ? scheme.onErrorContainer : null,
    );
    void tap() {
      HapticFeedback.selectionClick();
      onTap();
    }

    // Shrunk to fit when the row is narrow, beside the message box's buttons.
    final text = FittedBox(fit: BoxFit.scaleDown, child: Text(label));
    Widget key = active
        ? FilledButton(style: style, onPressed: tap, child: text)
        : FilledButton.tonal(style: style, onPressed: tap, child: text);

    if (repeat) {
      key = GestureDetector(
        onLongPressStart: (_) {
          HapticFeedback.selectionClick();
          onTap();
          _repeat = Timer.periodic(const Duration(milliseconds: 60), (_) => onTap());
        },
        onLongPressEnd: (_) => _repeat?.cancel(),
        onLongPressCancel: () => _repeat?.cancel(),
        child: key,
      );
    }
    return Expanded(child: Padding(padding: const EdgeInsets.symmetric(horizontal: 2), child: key));
  }

  @override
  Widget build(BuildContext context) {
    final w = widget;
    return Row(
      children: [
        _key('ESC', () => w.onKey(TerminalKey.escape)),
        _key('^C', () => w.onText('\x03'), danger: true),
        _key('TAB', () => w.onKey(TerminalKey.tab)),
        _key('⇧TAB', () => w.onKey(TerminalKey.tab, shift: true)),
        _key('CTRL', w.onCtrl, active: w.ctrl),
        _key('←', () => w.onKey(TerminalKey.arrowLeft), repeat: true),
        _key('↓', () => w.onKey(TerminalKey.arrowDown), repeat: true),
        _key('↑', () => w.onKey(TerminalKey.arrowUp), repeat: true),
        _key('→', () => w.onKey(TerminalKey.arrowRight), repeat: true),
      ],
    );
  }
}
