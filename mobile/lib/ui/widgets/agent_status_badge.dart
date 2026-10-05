import 'package:flutter/material.dart';
import '../../models/agent_status.dart';

/// Status icon plus the agent's name (or the status label when there's no agent).
class AgentStatusBadge extends StatelessWidget {
  final String status;
  final String? agentName;

  const AgentStatusBadge({super.key, required this.status, this.agentName});

  @override
  Widget build(BuildContext context) {
    final agentStatus = AgentStatusExtension.fromString(status);
    final color = agentStatus.color;
    return Tooltip(
      message: agentStatus.label,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: color.withOpacity(0.15),
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: color.withOpacity(0.4), width: 1),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(agentStatus.icon, size: 12, color: color),
            const SizedBox(width: 4),
            Text(
              agentName != null && agentName!.isNotEmpty ? agentName! : agentStatus.label,
              style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    );
  }
}
