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
        return 'Blocked (Needs Input)';
      case AgentStatus.done:
        return 'Done';
      case AgentStatus.idle:
        return 'Idle';
      case AgentStatus.unknown:
        return 'Shell';
    }
  }

  Color get color {
    switch (this) {
      case AgentStatus.working:
        return const Color(0xFF4CAF50); // Green
      case AgentStatus.blocked:
        return const Color(0xFFFF9800); // Amber/Orange
      case AgentStatus.done:
        return const Color(0xFF2196F3); // Blue
      case AgentStatus.idle:
        return const Color(0xFF9E9E9E); // Grey
      case AgentStatus.unknown:
        return const Color(0xFF607D8B); // Slate
    }
  }

  IconData get icon {
    switch (this) {
      case AgentStatus.working:
        return Icons.autorenew;
      case AgentStatus.blocked:
        return Icons.warning_amber_rounded;
      case AgentStatus.done:
        return Icons.check_circle_outline;
      case AgentStatus.idle:
        return Icons.pause_circle_outline;
      case AgentStatus.unknown:
        return Icons.terminal;
    }
  }
}
