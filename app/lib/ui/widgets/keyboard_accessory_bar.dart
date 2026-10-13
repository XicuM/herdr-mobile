import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart';

/// The keys a phone keyboard can't type. ⌘ is owned by the screen so it also applies to typed keys.
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

  /// M3 tonal buttons, [width] wide and 48 dp tall like the message box they replace. ⌘ turns filled while
  /// armed; ^C uses the error container. [repeat] keys fire again every 60 ms while held.
  Widget _key(double width, String label, VoidCallback onTap,
      {bool repeat = false, bool active = false, bool danger = false}) {
    final scheme = Theme.of(context).colorScheme;
    final style = FilledButton.styleFrom(
      minimumSize: const Size(0, 48),
      padding: EdgeInsets.zero,
      backgroundColor: danger ? scheme.errorContainer : null,
      foregroundColor: danger ? scheme.onErrorContainer : null,
    );
    void tap() {
      HapticFeedback.selectionClick();
      onTap();
    }

    final text = FittedBox(fit: BoxFit.scaleDown, child: Text(label));
    Widget key = active
        ? FilledButton(style: style, onPressed: tap, child: text)
        : FilledButton.tonal(style: style, onPressed: tap, child: text);

    if (repeat) {
      key = GestureDetector(
        onLongPressStart: (_) {
          HapticFeedback.selectionClick();
          onTap();
          // Holding a second key takes over from the first, whose timer would otherwise never stop.
          _repeat?.cancel();
          _repeat = Timer.periodic(const Duration(milliseconds: 60), (_) => onTap());
        },
        onLongPressEnd: (_) => _repeat?.cancel(),
        onLongPressCancel: () => _repeat?.cancel(),
        child: key,
      );
    }
    return Padding(padding: const EdgeInsets.symmetric(horizontal: 2), child: SizedBox(width: width, child: key));
  }

  /// The keys share the row out, but never narrower than a 48 dp touch target: past that, it scrolls sideways.
  @override
  Widget build(BuildContext context) {
    final w = widget;
    return LayoutBuilder(builder: (context, constraints) {
      final width = (constraints.maxWidth / 9 - 4).clamp(48.0, double.infinity);
      return SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            _key(width, 'ESC', () => w.onKey(TerminalKey.escape)),
            _key(width, '^C', () => w.onText('\x03'), danger: true),
            _key(width, 'TAB', () => w.onKey(TerminalKey.tab)),
            _key(width, '⇧TAB', () => w.onKey(TerminalKey.tab, shift: true)),
            _key(width, '⌘', w.onCtrl, active: w.ctrl),
            _key(width, '←', () => w.onKey(TerminalKey.arrowLeft), repeat: true),
            _key(width, '↓', () => w.onKey(TerminalKey.arrowDown), repeat: true),
            _key(width, '↑', () => w.onKey(TerminalKey.arrowUp), repeat: true),
            _key(width, '→', () => w.onKey(TerminalKey.arrowRight), repeat: true),
          ],
        ),
      );
    });
  }
}
