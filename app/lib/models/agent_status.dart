import 'package:flutter/material.dart';

enum AgentStatus {
  working('Working', Color(0xFFF9E2AF)), // yellow
  blocked('Blocked', Color(0xFFF38BA8)), // red
  done('Done', Color(0xFFA6E3A1)), // green
  idle('Idle', Color(0xFF6C7086)), // overlay grey
  unknown('No agent', Color(0xFF6C7086)); // idle's grey; the dot is hollow instead

  const AgentStatus(this.label, this.color);
  final String label;
  final Color color;

  static AgentStatus fromString(String? status) =>
      values.where((s) => s.name == status?.toLowerCase()).firstOrNull ?? unknown;
}

/// Filled in the status color; hollow when there's no agent.
class StatusDot extends StatelessWidget {
  final String? status;
  final double size;

  const StatusDot(this.status, {super.key, this.size = 8});

  @override
  Widget build(BuildContext context) {
    final s = AgentStatus.fromString(status);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: s == AgentStatus.unknown ? null : s.color,
        border: Border.all(color: s.color, width: 1.5),
      ),
    );
  }
}
