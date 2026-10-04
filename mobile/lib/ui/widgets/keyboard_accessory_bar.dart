import 'package:flutter/material.dart';

class KeyboardAccessoryBar extends StatefulWidget {
  final Function(String input) onSendInput;
  final Function(String key) onSendKey;

  const KeyboardAccessoryBar({
    super.key,
    required this.onSendInput,
    required this.onSendKey,
  });

  @override
  State<KeyboardAccessoryBar> createState() => _KeyboardAccessoryBarState();
}

class _KeyboardAccessoryBarState extends State<KeyboardAccessoryBar> {
  bool _ctrlActive = false;
  bool _altActive = false;

  void _handleKey(String key, String fallbackEsc) {
    if (_ctrlActive) {
      // Send Ctrl sequence
      if (key.length == 1) {
        int code = key.toUpperCase().codeUnitAt(0) - 64;
        if (code >= 1 && code <= 26) {
          widget.onSendInput(String.fromCharCode(code));
        }
      }
      setState(() => _ctrlActive = false);
    } else {
      widget.onSendKey(fallbackEsc);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final barBg = isDark ? const Color(0xFF1E1E1E) : const Color(0xFFEEEEEE);

    return Container(
      height: 48,
      color: barBg,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        children: [
          _buildButton(
            label: 'ESC',
            onTap: () => widget.onSendInput('\x1b'),
          ),
          _buildButton(
            label: 'TAB',
            onTap: () => widget.onSendInput('\t'),
          ),
          _buildToggleButton(
            label: 'CTRL',
            active: _ctrlActive,
            onTap: () => setState(() => _ctrlActive = !_ctrlActive),
          ),
          _buildToggleButton(
            label: 'ALT',
            active: _altActive,
            onTap: () => setState(() => _altActive = !_altActive),
          ),
          _buildButton(
            label: '↑',
            onTap: () => widget.onSendInput('\x1b[A'),
          ),
          _buildButton(
            label: '↓',
            onTap: () => widget.onSendInput('\x1b[B'),
          ),
          _buildButton(
            label: '←',
            onTap: () => widget.onSendInput('\x1b[D'),
          ),
          _buildButton(
            label: '→',
            onTap: () => widget.onSendInput('\x1b[C'),
          ),
          _buildButton(
            label: '^C',
            color: Colors.redAccent.withOpacity(0.2),
            textColor: Colors.redAccent,
            onTap: () => widget.onSendInput('\x03'),
          ),
          _buildButton(
            label: 'ENTER',
            onTap: () => widget.onSendInput('\r'),
          ),
        ],
      ),
    );
  }

  Widget _buildButton({
    required String label,
    required VoidCallback onTap,
    Color? color,
    Color? textColor,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Material(
        color: color ?? Colors.white.withOpacity(0.08),
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: onTap,
          child: Container(
            constraints: const BoxConstraints(minWidth: 44),
            padding: const EdgeInsets.symmetric(horizontal: 10),
            alignment: Alignment.center,
            child: Text(
              label,
              style: TextStyle(
                color: textColor ?? Colors.white70,
                fontSize: 13,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildToggleButton({
    required String label,
    required bool active,
    required VoidCallback onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Material(
        color: active ? Colors.blueAccent : Colors.white.withOpacity(0.08),
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: onTap,
          child: Container(
            constraints: const BoxConstraints(minWidth: 44),
            padding: const EdgeInsets.symmetric(horizontal: 10),
            alignment: Alignment.center,
            child: Text(
              label,
              style: TextStyle(
                color: active ? Colors.white : Colors.white70,
                fontSize: 13,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
