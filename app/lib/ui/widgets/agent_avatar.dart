import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../models/agent_status.dart';

enum AgentKind {
  antigravity,
  claude,
  gemini,
  codex,
  grok,
  aider,
  cursor,
  copilot,
  cline,
  terminal;

  static AgentKind fromName(String name) {
    final lower = name.toLowerCase();
    if (lower.contains('antigravity') || lower.contains('agy') || lower.contains('antigrav')) {
      return antigravity;
    }
    if (lower.contains('claude') || lower.contains('anthropic')) {
      return claude;
    }
    if (lower.contains('gemini') || lower.contains('google')) {
      return gemini;
    }
    if (lower.contains('codex') || lower.contains('chatgpt') || lower.contains('openai') || lower.contains('gpt')) {
      return codex;
    }
    if (lower.contains('grok') || lower.contains('xai')) {
      return grok;
    }
    if (lower.contains('aider')) {
      return aider;
    }
    if (lower.contains('cursor')) {
      return cursor;
    }
    if (lower.contains('copilot') || lower.contains('github')) {
      return copilot;
    }
    if (lower.contains('cline')) {
      return cline;
    }
    return terminal;
  }
}

/// Canonical Material 3 Avatar representing the actual logo of each AI agent, badged with [StatusDot].
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
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final kind = AgentKind.fromName(name);

    final (painter, bgColor, borderColor) = _buildAgentVisuals(kind, scheme, isDark);

    final avatar = Container(
      width: radius * 2,
      height: radius * 2,
      decoration: BoxDecoration(
        color: bgColor,
        shape: BoxShape.circle,
        border: borderColor != null ? Border.all(color: borderColor, width: 1) : null,
      ),
      child: Center(
        child: SizedBox(
          width: radius * 1.35,
          height: radius * 1.35,
          child: CustomPaint(painter: painter),
        ),
      ),
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

  (CustomPainter, Color, Color?) _buildAgentVisuals(
    AgentKind kind,
    ColorScheme scheme,
    bool isDark,
  ) {
    switch (kind) {
      case AgentKind.antigravity:
        return (
          const _AntigravityPainter(),
          isDark ? const Color(0xFF1E1B4B) : const Color(0xFF312E81),
          const Color(0xFF6366F1).withValues(alpha: 0.4),
        );

      case AgentKind.claude:
        return (
          const _ClaudePainter(color: Color(0xFFD97757)),
          isDark ? const Color(0xFF2B211B) : const Color(0xFFFBF0EA),
          isDark ? const Color(0xFF4A3428) : const Color(0xFFF0DCD3),
        );

      case AgentKind.gemini:
        return (
          const _GeminiPainter(),
          isDark ? const Color(0xFF0F172A) : const Color(0xFFE8F0FE),
          isDark ? const Color(0xFF1E293B) : const Color(0xFFD2E3FC),
        );

      case AgentKind.codex:
        return (
          const _OpenAiPainter(color: Color(0xFF10A37F)),
          isDark ? const Color(0xFF0A1F1C) : const Color(0xFFE6F7F2),
          isDark ? const Color(0xFF163E38) : const Color(0xFFC7EFE4),
        );

      case AgentKind.grok:
        return (
          const _GrokPainter(color: Colors.white),
          const Color(0xFF09090B),
          isDark ? const Color(0xFF27272A) : const Color(0xFF3F3F46),
        );

      case AgentKind.aider:
        return (
          const _AiderPainter(color: Colors.white),
          isDark ? const Color(0xFF4C1D95) : const Color(0xFF6D28D9),
          null,
        );

      case AgentKind.cursor:
        return (
          const _CursorPainter(),
          const Color(0xFF18181B),
          isDark ? const Color(0xFF27272A) : const Color(0xFF3F3F46),
        );

      case AgentKind.copilot:
        return (
          const _CopilotPainter(color: Colors.white),
          isDark ? const Color(0xFF1F242C) : const Color(0xFF24292F),
          null,
        );

      case AgentKind.cline:
        return (
          const _ClinePainter(),
          isDark ? const Color(0xFF1E3A8A) : const Color(0xFF2563EB),
          null,
        );

      case AgentKind.terminal:
        return (
          _TerminalPromptPainter(color: scheme.onSurfaceVariant),
          scheme.surfaceContainerHighest,
          scheme.outlineVariant.withValues(alpha: 0.5),
        );
    }
  }
}

/// Official Anthropic Claude terracotta radial starburst logo.
class _ClaudePainter extends CustomPainter {
  final Color color;
  const _ClaudePainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2;
    // 14 spokes of the Anthropic Claude asterisk with characteristic organic varying lengths
    const rayScales = [
      0.95, 0.72, 1.00, 0.78, 0.92, 0.68, 0.98,
      0.82, 0.95, 0.70, 1.00, 0.76, 0.92, 0.74,
    ];
    final paint = Paint()
      ..color = color
      ..strokeWidth = size.width * 0.125
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    final innerRadius = radius * 0.15;
    for (var i = 0; i < 14; i++) {
      final angle = (i * 2 * math.pi / 14) - (math.pi / 2);
      final outerRadius = radius * rayScales[i] * 0.92;
      final p1 = Offset(center.dx + math.cos(angle) * innerRadius, center.dy + math.sin(angle) * innerRadius);
      final p2 = Offset(center.dx + math.cos(angle) * outerRadius, center.dy + math.sin(angle) * outerRadius);
      canvas.drawLine(p1, p2, paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Official Google Gemini 4-pointed sparkle star with rich gradient.
class _GeminiPainter extends CustomPainter {
  const _GeminiPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;
    final r = size.width * 0.44;

    final path = Path()
      ..moveTo(cx, cy - r)
      ..quadraticBezierTo(cx + r * 0.15, cy - r * 0.15, cx + r, cy)
      ..quadraticBezierTo(cx + r * 0.15, cy + r * 0.15, cx, cy + r)
      ..quadraticBezierTo(cx - r * 0.15, cy + r * 0.15, cx - r, cy)
      ..quadraticBezierTo(cx - r * 0.15, cy - r * 0.15, cx, cy - r)
      ..close();

    final paint = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          Color(0xFF4285F4), // Google Blue
          Color(0xFF9B51E0), // Purple
          Color(0xFFE91E63), // Pink
          Color(0xFFFF7043), // Coral
        ],
      ).createShader(Rect.fromLTWH(cx - r, cy - r, 2 * r, 2 * r))
      ..style = PaintingStyle.fill;

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Official OpenAI / ChatGPT 6-segment spiral rosette logo.
class _OpenAiPainter extends CustomPainter {
  final Color color;
  const _OpenAiPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;
    final scale = size.width / 100;

    final paint = Paint()
      ..color = color
      ..strokeWidth = 6.5 * scale
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;

    canvas.save();
    canvas.translate(cx, cy);

    for (var i = 0; i < 6; i++) {
      canvas.save();
      canvas.rotate(i * math.pi / 3);

      final path = Path()
        ..moveTo(0, -5 * scale)
        ..lineTo(0, -30 * scale)
        ..quadraticBezierTo(0, -40 * scale, 9 * scale, -40 * scale)
        ..lineTo(19 * scale, -34 * scale)
        ..quadraticBezierTo(26 * scale, -30 * scale, 23 * scale, -20 * scale)
        ..lineTo(9 * scale, 4 * scale)
        ..quadraticBezierTo(4 * scale, 12 * scale, -6 * scale, 8 * scale);

      canvas.drawPath(path, paint);
      canvas.restore();
    }

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Google DeepMind Antigravity quantum levitation delta logo.
class _AntigravityPainter extends CustomPainter {
  const _AntigravityPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;
    final r = size.width * 0.42;

    // Outer inverted triangle with rounded vertices
    final outerPath = Path();
    final p1 = Offset(cx - r * 0.866, cy - r * 0.5); // top left
    final p2 = Offset(cx + r * 0.866, cy - r * 0.5); // top right
    final p3 = Offset(cx, cy + r * 0.8); // bottom tip

    final strokePaint = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Color(0xFF38BDF8), Color(0xFF818CF8), Color(0xFFC084FC)],
      ).createShader(Rect.fromCircle(center: Offset(cx, cy), radius: r))
      ..style = PaintingStyle.stroke
      ..strokeWidth = size.width * 0.08
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    outerPath.moveTo(p1.dx, p1.dy);
    outerPath.lineTo(p2.dx, p2.dy);
    outerPath.lineTo(p3.dx, p3.dy);
    outerPath.close();
    canvas.drawPath(outerPath, strokePaint);

    // Inner glowing core / levitating orbital node
    final corePaint = Paint()
      ..shader = const RadialGradient(
        colors: [Color(0xFFFFFFFF), Color(0xFF38BDF8), Color(0x00818CF8)],
      ).createShader(Rect.fromCircle(center: Offset(cx, cy - r * 0.05), radius: r * 0.35))
      ..style = PaintingStyle.fill;
    canvas.drawCircle(Offset(cx, cy - r * 0.05), r * 0.22, corePaint);

    // Floating upward vector
    final innerPath = Path()
      ..moveTo(cx - r * 0.32, cy + r * 0.15)
      ..lineTo(cx, cy - r * 0.22)
      ..lineTo(cx + r * 0.32, cy + r * 0.15);
    final chevronPaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = size.width * 0.06
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawPath(innerPath, chevronPaint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// xAI Grok geometric slash logo.
class _GrokPainter extends CustomPainter {
  final Color color;
  const _GrokPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;
    final r = size.width * 0.36;

    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = size.width * 0.11
      ..strokeCap = StrokeCap.round;

    // Main diagonal slash \
    canvas.drawLine(Offset(cx - r * 0.8, cy - r), Offset(cx + r * 0.8, cy + r), paint);

    // Forward slash / segments
    canvas.drawLine(Offset(cx + r * 0.8, cy - r), Offset(cx + r * 0.2, cy - r * 0.25), paint);
    canvas.drawLine(Offset(cx - r * 0.2, cy + r * 0.25), Offset(cx - r * 0.8, cy + r), paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Aider AI cute robot head logo.
class _AiderPainter extends CustomPainter {
  final Color color;
  const _AiderPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;

    // Robot head
    final headRect = RRect.fromRectAndRadius(
      Rect.fromCenter(
        center: Offset(cx, cy + size.height * 0.05),
        width: size.width * 0.58,
        height: size.height * 0.46,
      ),
      Radius.circular(size.width * 0.1),
    );
    final headPaint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = size.width * 0.07;
    canvas.drawRRect(headRect, headPaint);

    // Eyes
    final eyePaint = Paint()
      ..color = const Color(0xFF22D3EE)
      ..style = PaintingStyle.fill;
    final leftEye = RRect.fromRectAndRadius(
      Rect.fromCenter(
        center: Offset(cx - size.width * 0.14, cy + size.height * 0.05),
        width: size.width * 0.12,
        height: size.height * 0.12,
      ),
      Radius.circular(size.width * 0.03),
    );
    final rightEye = RRect.fromRectAndRadius(
      Rect.fromCenter(
        center: Offset(cx + size.width * 0.14, cy + size.height * 0.05),
        width: size.width * 0.12,
        height: size.height * 0.12,
      ),
      Radius.circular(size.width * 0.03),
    );
    canvas.drawRRect(leftEye, eyePaint);
    canvas.drawRRect(rightEye, eyePaint);

    // Antenna
    final antennaPaint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = size.width * 0.06
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(
      Offset(cx, cy - size.height * 0.18),
      Offset(cx, cy - size.height * 0.28),
      antennaPaint,
    );
    canvas.drawCircle(
      Offset(cx, cy - size.height * 0.32),
      size.width * 0.045,
      Paint()..color = const Color(0xFF22D3EE),
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Cursor 3D isometric cube prism logo.
class _CursorPainter extends CustomPainter {
  const _CursorPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;
    final r = size.width * 0.38;

    final topFace = Path()
      ..moveTo(cx, cy - r)
      ..lineTo(cx + r * 0.866, cy - r * 0.5)
      ..lineTo(cx, cy)
      ..lineTo(cx - r * 0.866, cy - r * 0.5)
      ..close();

    final leftFace = Path()
      ..moveTo(cx - r * 0.866, cy - r * 0.5)
      ..lineTo(cx, cy)
      ..lineTo(cx, cy + r)
      ..lineTo(cx - r * 0.866, cy + r * 0.5)
      ..close();

    final rightFace = Path()
      ..moveTo(cx, cy)
      ..lineTo(cx + r * 0.866, cy - r * 0.5)
      ..lineTo(cx + r * 0.866, cy + r * 0.5)
      ..lineTo(cx, cy + r)
      ..close();

    canvas.drawPath(topFace, Paint()..color = Colors.white);
    canvas.drawPath(leftFace, Paint()..color = const Color(0xFFA1A1AA));
    canvas.drawPath(rightFace, Paint()..color = const Color(0xFF52525B));
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// GitHub Copilot robot visor logo.
class _CopilotPainter extends CustomPainter {
  final Color color;
  const _CopilotPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;
    final r = size.width * 0.36;

    final headRect = RRect.fromRectAndRadius(
      Rect.fromCenter(center: Offset(cx, cy), width: r * 1.8, height: r * 1.4),
      Radius.circular(r * 0.5),
    );
    canvas.drawRRect(
      headRect,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = size.width * 0.07,
    );

    final visorRect = RRect.fromRectAndRadius(
      Rect.fromCenter(center: Offset(cx, cy), width: r * 1.3, height: r * 0.4),
      Radius.circular(r * 0.2),
    );
    canvas.drawRRect(visorRect, Paint()..color = const Color(0xFF58A6FF));

    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(center: Offset(cx - r * 0.95, cy), width: r * 0.22, height: r * 0.65),
        Radius.circular(r * 0.1),
      ),
      Paint()..color = color,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(center: Offset(cx + r * 0.95, cy), width: r * 0.22, height: r * 0.65),
        Radius.circular(r * 0.1),
      ),
      Paint()..color = color,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Cline robot mascot logo.
class _ClinePainter extends CustomPainter {
  const _ClinePainter();

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;
    final r = size.width * 0.38;

    final body = RRect.fromRectAndRadius(
      Rect.fromCenter(center: Offset(cx, cy + r * 0.1), width: r * 1.7, height: r * 1.4),
      Radius.circular(r * 0.4),
    );
    canvas.drawRRect(
      body,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = size.width * 0.07,
    );

    final screen = RRect.fromRectAndRadius(
      Rect.fromCenter(center: Offset(cx, cy + r * 0.1), width: r * 1.2, height: r * 0.6),
      Radius.circular(r * 0.2),
    );
    canvas.drawRRect(screen, Paint()..color = const Color(0xFF38BDF8));

    canvas.drawCircle(Offset(cx - r * 0.3, cy + r * 0.1), r * 0.12, Paint()..color = Colors.white);
    canvas.drawCircle(Offset(cx + r * 0.3, cy + r * 0.1), r * 0.12, Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Terminal command prompt `>_` logo.
class _TerminalPromptPainter extends CustomPainter {
  final Color color;
  const _TerminalPromptPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;
    final r = size.width * 0.35;

    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = size.width * 0.09
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final chevron = Path()
      ..moveTo(cx - r * 0.7, cy - r * 0.55)
      ..lineTo(cx - r * 0.05, cy)
      ..lineTo(cx - r * 0.7, cy + r * 0.55);
    canvas.drawPath(chevron, paint);

    canvas.drawLine(
      Offset(cx + r * 0.15, cy + r * 0.55),
      Offset(cx + r * 0.8, cy + r * 0.55),
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
