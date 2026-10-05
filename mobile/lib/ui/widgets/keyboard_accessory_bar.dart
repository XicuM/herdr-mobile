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

  /// [repeat] keys fire again every 60 ms while held.
  Widget _key(String label, VoidCallback onTap, {bool repeat = false, bool active = false, Color? color}) {
    Widget key = Material(
      color: active
          ? Theme.of(context).colorScheme.primary
          : (color ?? Colors.white).withOpacity(color != null ? 0.2 : 0.08),
      borderRadius: BorderRadius.circular(6),
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: () {
          HapticFeedback.selectionClick();
          onTap();
        },
        child: Center(
          child: Text(
            label,
            style: TextStyle(
              color: active ? Colors.white : (color ?? Colors.white70),
              fontSize: 12,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ),
    );
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
    return Expanded(child: Padding(padding: const EdgeInsets.all(3), child: key));
  }

  @override
  Widget build(BuildContext context) {
    final w = widget;
    return Container(
      height: 46,
      color: Theme.of(context).colorScheme.surface,
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 3),
      child: Row(
        children: [
          _key('ESC', () => w.onKey(TerminalKey.escape)),
          _key('^C', () => w.onText('\x03'), color: Colors.redAccent),
          _key('TAB', () => w.onKey(TerminalKey.tab)),
          _key('⇧TAB', () => w.onKey(TerminalKey.tab, shift: true)),
          _key('CTRL', w.onCtrl, active: w.ctrl),
          _key('←', () => w.onKey(TerminalKey.arrowLeft), repeat: true),
          _key('↓', () => w.onKey(TerminalKey.arrowDown), repeat: true),
          _key('↑', () => w.onKey(TerminalKey.arrowUp), repeat: true),
          _key('→', () => w.onKey(TerminalKey.arrowRight), repeat: true),
        ],
      ),
    );
  }
}
