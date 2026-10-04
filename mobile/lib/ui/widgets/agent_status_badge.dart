import 'package:flutter/material.dart';
import '../../models/agent_status.dart';

class AgentStatusBadge extends StatelessWidget {
  final String status;
  final String? agentName;
  final bool compact;

  const AgentStatusBadge({
    super.key,
    required this.status,
    this.agentName,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final agentStatus = AgentStatusExtension.fromString(status);
    final color = agentStatus.color;

    if (compact) {
      return Container(
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
              style: TextStyle(
                color: color,
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withOpacity(0.15),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color, width: 1.2),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(agentStatus.icon, size: 14, color: color),
          const SizedBox(width: 6),
          Text(
            agentName != null && agentName!.isNotEmpty
                ? '$agentName (${agentStatus.label})'
                : agentStatus.label,
            style: TextStyle(
              color: color,
              fontSize: 12,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }
}
