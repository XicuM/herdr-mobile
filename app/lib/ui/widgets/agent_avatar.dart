import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import '../../models/agent_status.dart';

/// Name fragments herdr reports → the agent's logo in `assets/logos/` and its brand tint (null follows the
/// scheme, so black marks show in dark mode too). The first match wins.
const _logos = [
  (['antigravity', 'agy'], 'antigravity.png', null),
  (['claude', 'anthropic'], 'claude.svg', Color(0xFFD97757)),
  (['gemini'], 'gemini.svg', Color(0xFF4285F4)),
  (['codex', 'openai', 'gpt'], 'openai.svg', Color(0xFF10A37F)),
  (['grok'], 'grok.svg', null),
  (['cursor'], 'cursor.svg', null),
  (['copilot'], 'copilot.svg', null),
  (['opencode'], 'opencode.svg', null),
];

final _iconCache = <String, Uint8List>{};
final _iconPathCache = <String, String>{};

/// Pre-warms notification icons in the background.
Future<void> warmAgentIcons() async {
  for (final (_, file, _) in _logos) {
    try {
      await _renderIcon(file);
    } catch (_) {}
  }
}

/// Returns the cached notification icon bytes for [name], or null if not found.
Uint8List? agentIconBytes(String name) {
  final lower = name.toLowerCase();
  final logo = _logos.where((l) => l.$1.any(lower.contains)).firstOrNull;
  if (logo == null) return null;
  final (_, file, _) = logo;
  if (!_iconCache.containsKey(file)) {
    _renderIcon(file).ignore();
    return null;
  }
  return _iconCache[file];
}

/// Returns the cached notification icon file path on Linux for [name], or null if not found.
String? agentIconPath(String name) {
  final lower = name.toLowerCase();
  final logo = _logos.where((l) => l.$1.any(lower.contains)).firstOrNull;
  if (logo == null) return null;
  final (_, file, _) = logo;
  if (!_iconPathCache.containsKey(file)) {
    final bytes = _iconCache[file];
    if (bytes != null && Platform.isLinux) {
      try {
        final clean = file.replaceAll('.svg', '').replaceAll('.png', '');
        final f = File('${Directory.systemTemp.path}/herdr_logo_$clean.png');
        if (!f.existsSync()) f.writeAsBytesSync(bytes);
        _iconPathCache[file] = f.path;
      } catch (_) {}
    } else {
      _renderIcon(file).ignore();
    }
  }
  return _iconPathCache[file];
}

Future<Uint8List?> _renderIcon(String file) async {
  if (_iconCache.containsKey(file)) return _iconCache[file];
  final logo = _logos.where((l) => l.$2 == file).firstOrNull;
  if (logo == null) return null;
  final (_, _, tint) = logo;
  const size = 128.0;
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder, const Rect.fromLTWH(0, 0, size, size));
  final bgPaint = Paint()..color = const Color(0xFF2C2D30);
  canvas.drawCircle(const Offset(size / 2, size / 2), size / 2, bgPaint);

  if (file.endsWith('.png')) {
    final data = await rootBundle.load('assets/logos/$file');
    final codec = await ui.instantiateImageCodec(data.buffer.asUint8List());
    final frame = await codec.getNextFrame();
    final img = frame.image;
    final src = Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble());
    final dst = Rect.fromCircle(center: const Offset(size / 2, size / 2), radius: size * 0.35);
    canvas.drawImageRect(img, src, dst, Paint());
  } else {
    final color = tint ?? Colors.white;
    final filter = file == 'cursor.svg' ? null : ColorFilter.mode(color, BlendMode.srcIn);
    final loader = SvgAssetLoader('assets/logos/$file');
    final pictureInfo = await vg.loadPicture(loader, null);
    final pic = pictureInfo.picture;
    final picSize = pictureInfo.size;
    final scale = (size * 0.6) / (picSize.width > picSize.height ? picSize.width : picSize.height);
    canvas.save();
    canvas.translate((size - picSize.width * scale) / 2, (size - picSize.height * scale) / 2);
    canvas.scale(scale);
    if (filter != null) {
      canvas.saveLayer(null, Paint()..colorFilter = filter);
      canvas.drawPicture(pic);
      canvas.restore();
    } else {
      canvas.drawPicture(pic);
    }
    canvas.restore();
  }

  final picture = recorder.endRecording();
  final img = await picture.toImage(size.toInt(), size.toInt());
  final byteData = await img.toByteData(format: ui.ImageByteFormat.png);
  final bytes = byteData?.buffer.asUint8List();
  if (bytes != null) {
    _iconCache[file] = bytes;
    if (Platform.isLinux) {
      try {
        final clean = file.replaceAll('.svg', '').replaceAll('.png', '');
        final f = File('${Directory.systemTemp.path}/herdr_logo_$clean.png');
        if (!f.existsSync()) f.writeAsBytesSync(bytes);
        _iconPathCache[file] = f.path;
      } catch (_) {}
    }
  }
  return bytes;
}


/// A Material 3 avatar with the agent's logo and an optional online status ring.
class AgentAvatar extends StatelessWidget {
  final String name;
  final double radius;
  final String? status;

  const AgentAvatar({super.key, required this.name, this.radius = 20, this.status});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final lower = name.toLowerCase();
    final logo = _logos.where((l) => l.$1.any(lower.contains)).firstOrNull;
    final size = radius * 1.2;
    final agentStatus = status != null ? AgentStatus.fromString(status) : null;
    final hasRing = agentStatus != null && agentStatus != AgentStatus.unknown;

    Widget avatar = CircleAvatar(
      radius: radius,
      backgroundColor: scheme.surfaceContainerHighest,
      child: switch (logo) {
        null => Icon(Icons.terminal, size: size, color: scheme.onSurfaceVariant),
        (_, final file, _) when file.endsWith('.png') => Image.asset('assets/logos/$file', width: size, height: size),
        (_, final file, final tint) => SvgPicture.asset(
            'assets/logos/$file',
            width: size,
            height: size,
            // Cursor's cube keeps its own colours.
            colorFilter: file == 'cursor.svg' ? null : ColorFilter.mode(tint ?? scheme.onSurface, BlendMode.srcIn),
          ),
      },
    );

    if (hasRing) {
      final ringWidth = radius <= 12 ? 2.5 : 3.0;
      final ringPadding = radius <= 12 ? 1.0 : 1.5;
      return Container(
        padding: EdgeInsets.all(ringPadding),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: agentStatus.color, width: ringWidth),
        ),
        child: avatar,
      );
    }
    return avatar;
  }
}

/// A compact icon widget for an agent logo, optionally tinted monochrome with [color].
class AgentIcon extends StatelessWidget {
  final String name;
  final double size;
  final Color? color;

  const AgentIcon({super.key, required this.name, this.size = 16, this.color});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final lower = name.toLowerCase();
    final logo = _logos.where((l) => l.$1.any(lower.contains)).firstOrNull;
    final effectiveColor = color ?? scheme.onSurface;

    return switch (logo) {
      null => Icon(Icons.terminal, size: size, color: effectiveColor),
      (_, final file, _) when file.endsWith('.png') => Image.asset(
          'assets/logos/$file',
          width: size,
          height: size,
          color: color,
          colorBlendMode: color != null ? BlendMode.srcIn : null,
        ),
      (_, final file, final tint) => SvgPicture.asset(
          'assets/logos/$file',
          width: size,
          height: size,
          colorFilter: ColorFilter.mode(color ?? tint ?? scheme.onSurface, BlendMode.srcIn),
        ),
    };
  }
}
