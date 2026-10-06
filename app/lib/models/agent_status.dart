import 'package:flutter/material.dart';

enum AgentStatus {
  working(Color(0xFFF9E2AF)), // yellow
  blocked(Color(0xFFF38BA8)), // red: needs you
  done(Color(0xFFA6E3A1)), // green
  idle(Color(0xFF6C7086)), // overlay grey
  unknown(Color(0xFF6C7086)); // no agent: idle's grey, but the dot is hollow

  const AgentStatus(this.color);
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
