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

/// Canonical Material 3 Avatar representing the AI agent engine, badged with [StatusDot].
class AgentAvatar extends StatelessWidget {
  final String name;
  final String? status;
  final double radius;

  const AgentAvatar({
    super.key,
    required this.name,
    this.status,
    this.radius = 22,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final kind = AgentKind.fromName(name);

    final (icon, bgColor, fgColor) = switch (kind) {
      AgentKind.antigravity => (Icons.change_history_rounded, scheme.primaryContainer, scheme.onPrimaryContainer),
      AgentKind.claude => (Icons.auto_awesome, scheme.tertiaryContainer, scheme.onTertiaryContainer),
      AgentKind.gemini => (Icons.flare_rounded, scheme.secondaryContainer, scheme.onSecondaryContainer),
      AgentKind.codex => (Icons.hub_rounded, scheme.primaryContainer, scheme.onPrimaryContainer),
      AgentKind.grok => (Icons.close_rounded, scheme.surfaceContainerHighest, scheme.onSurfaceVariant),
      AgentKind.aider => (Icons.smart_toy_rounded, scheme.tertiaryContainer, scheme.onTertiaryContainer),
      AgentKind.terminal => (Icons.terminal_rounded, scheme.surfaceContainerHighest, scheme.onSurfaceVariant),
    };

    final avatar = CircleAvatar(
      radius: radius,
      backgroundColor: bgColor,
      foregroundColor: fgColor,
      child: Icon(icon, size: radius * 1.1),
    );

    if (status == null) return avatar;

    final agentStatus = AgentStatus.fromString(status);
    return Badge(
      alignment: Alignment.bottomRight,
      backgroundColor: agentStatus == AgentStatus.unknown ? Colors.transparent : agentStatus.color,
      smallSize: 10,
      child: avatar,
    );
  }
}
