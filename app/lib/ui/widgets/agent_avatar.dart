import 'package:flutter/material.dart';
import '../../models/agent_status.dart';

enum AgentKind {
  antigravity,
  claude,
  gemini,
  codex,
  grok,
  aider,
  terminal;

  static AgentKind fromName(String name) {
    final lower = name.toLowerCase();
    if (lower.contains('antigravity') || lower.contains('agy')) return antigravity;
    if (lower.contains('claude')) return claude;
    if (lower.contains('gemini') || lower.contains('google')) return gemini;
    if (lower.contains('codex') || lower.contains('chatgpt') || lower.contains('openai')) return codex;
    if (lower.contains('grok')) return grok;
    if (lower.contains('aider')) return aider;
    return terminal;
  }
}

/// Avatar icon representing the AI agent tool/engine (Antigravity, Claude, Gemini, etc.)
/// with an integrated [StatusDot] badge in the bottom-right corner.
class AgentAvatar extends StatelessWidget {
  final String name;
  final String? status;
  final double size;

  const AgentAvatar({
    super.key,
    required this.name,
    this.status,
    this.size = 44,
  });

  @override
  Widget build(BuildContext context) {
    final kind = AgentKind.fromName(name);
    final (icon, bgColor, iconColor) = switch (kind) {
      AgentKind.antigravity => (
          Icons.change_history_rounded,
          const Color(0xFF0284C7).withOpacity(0.18),
          const Color(0xFF0284C7),
        ),
      AgentKind.claude => (
          Icons.auto_awesome,
          const Color(0xFFD97706).withOpacity(0.18),
          const Color(0xFFD97706),
        ),
      AgentKind.gemini => (
          Icons.flare_rounded,
          const Color(0xFF6366F1).withOpacity(0.18),
          const Color(0xFF6366F1),
        ),
      AgentKind.codex => (
          Icons.hub_rounded,
          const Color(0xFF10A37F).withOpacity(0.18),
          const Color(0xFF10A37F),
        ),
      AgentKind.grok => (
          Icons.close_rounded,
          const Color(0xFF475569).withOpacity(0.18),
          const Color(0xFF475569),
        ),
      AgentKind.aider => (
          Icons.smart_toy_rounded,
          const Color(0xFF8B5CF6).withOpacity(0.18),
          const Color(0xFF8B5CF6),
        ),
      AgentKind.terminal => (
          Icons.terminal_rounded,
          const Color(0xFF64748B).withOpacity(0.18),
          const Color(0xFF64748B),
        ),
    };

    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: bgColor,
            ),
            child: Icon(
              icon,
              size: size * 0.52,
              color: iconColor,
            ),
          ),
          if (status != null)
            Positioned(
              right: 0,
              bottom: 0,
              child: Container(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Theme.of(context).colorScheme.surface,
                ),
                padding: const EdgeInsets.all(2),
                child: StatusDot(status, size: size * 0.28),
              ),
            ),
        ],
      ),
    );
  }
}
