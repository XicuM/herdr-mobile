import 'package:flutter/material.dart';

enum AgentStatus {
  working,
  blocked,
  done,
  idle,
  unknown,
}

extension AgentStatusExtension on AgentStatus {
  static AgentStatus fromString(String? status) {
    switch (status?.toLowerCase()) {
      case 'working':
        return AgentStatus.working;
      case 'blocked':
        return AgentStatus.blocked;
      case 'done':
        return AgentStatus.done;
      case 'idle':
        return AgentStatus.idle;
      default:
        return AgentStatus.unknown;
    }
  }

  String get label {
    switch (this) {
      case AgentStatus.working:
        return 'Working';
      case AgentStatus.blocked:
        return 'Blocked';
      case AgentStatus.done:
        return 'Done';
      case AgentStatus.idle:
        return 'Idle';
      case AgentStatus.unknown:
        return 'No agent';
    }
  }

  Color get color {
    switch (this) {
      case AgentStatus.working:
        return const Color(0xFFF9E2AF); // Yellow
      case AgentStatus.blocked:
        return const Color(0xFFF38BA8); // Red
      case AgentStatus.done:
        return const Color(0xFFA6E3A1); // Green
      case AgentStatus.idle:
        return const Color(0xFF6C7086); // Overlay grey
      case AgentStatus.unknown:
        return const Color(0xFF64748B); // Muted Slate
    }
  }
}

/// Filled in the status color; hollow when there's no agent.
class StatusDot extends StatelessWidget {
  final String? status;
  final double size;

  const StatusDot(this.status, {super.key, this.size = 8});

  @override
  Widget build(BuildContext context) {
    final s = AgentStatusExtension.fromString(status);
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
