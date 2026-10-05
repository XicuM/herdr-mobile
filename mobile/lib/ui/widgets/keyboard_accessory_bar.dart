import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart';

/// Keys a phone keyboard lacks. ESC and ^C stay pinned left, compose and ENTER pinned right;
/// the rest scroll in between. CTRL/ALT are owned by the screen so they also apply to typed keys.
class KeyboardAccessoryBar extends StatefulWidget {
  final bool ctrl;
  final bool alt;
  final VoidCallback onCtrl;
  final VoidCallback onAlt;
  final void Function(TerminalKey key, {bool shift}) onKey;
  final void Function(String text) onText;
  final VoidCallback onPaste;
  final VoidCallback onCopy;
  final VoidCallback onCompose;

  const KeyboardAccessoryBar({
    super.key,
    required this.ctrl,
    required this.alt,
    required this.onCtrl,
    required this.onAlt,
    required this.onKey,
    required this.onText,
    required this.onPaste,
    required this.onCopy,
    required this.onCompose,
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
  Widget _key(String label, VoidCallback onTap,
      {IconData? icon, bool repeat = false, bool active = false, Color? color, String? tooltip}) {
    final fg = active ? Colors.white : (color ?? Colors.white70);
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
        child: Container(
          constraints: const BoxConstraints(minWidth: 40),
          padding: const EdgeInsets.symmetric(horizontal: 10),
          alignment: Alignment.center,
          child: icon != null
              ? Icon(icon, size: 18, color: fg)
              : Text(label, style: TextStyle(color: fg, fontSize: 13, fontWeight: FontWeight.bold)),
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
    if (tooltip != null) key = Tooltip(message: tooltip, child: key);
    return Padding(padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 6), child: key);
  }

  @override
  Widget build(BuildContext context) {
    final w = widget;
    return Container(
      height: 48,
      color: Theme.of(context).colorScheme.surface,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        children: [
          _key('ESC', () => w.onKey(TerminalKey.escape)),
          _key('^C', () => w.onText('\x03'), color: Colors.redAccent),
          Expanded(
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                _key('TAB', () => w.onKey(TerminalKey.tab)),
                _key('⇧TAB', () => w.onKey(TerminalKey.tab, shift: true)),
                _key('CTRL', w.onCtrl, active: w.ctrl),
                _key('ALT', w.onAlt, active: w.alt),
                _key('←', () => w.onKey(TerminalKey.arrowLeft), repeat: true),
                _key('↓', () => w.onKey(TerminalKey.arrowDown), repeat: true),
                _key('↑', () => w.onKey(TerminalKey.arrowUp), repeat: true),
                _key('→', () => w.onKey(TerminalKey.arrowRight), repeat: true),
                _key('HOME', () => w.onKey(TerminalKey.home)),
                _key('END', () => w.onKey(TerminalKey.end)),
                _key('PGUP', () => w.onKey(TerminalKey.pageUp), repeat: true),
                _key('PGDN', () => w.onKey(TerminalKey.pageDown), repeat: true),
                for (final c in ['|', '/', '~', '-']) _key(c, () => w.onText(c)),
                _key('', w.onPaste, icon: Icons.content_paste, tooltip: 'Paste'),
                _key('', w.onCopy, icon: Icons.content_copy, tooltip: 'Copy selection'),
              ],
            ),
          ),
          _key('', w.onCompose, icon: Icons.edit_note, tooltip: 'Compose'),
          _key('', () => w.onKey(TerminalKey.enter), icon: Icons.keyboard_return, tooltip: 'Enter'),
        ],
      ),
    );
  }
}
