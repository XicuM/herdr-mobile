import 'dart:io' show Process;
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

/// An image picked for the message box, normalized for upload: the bridge saves it where the
/// agent runs and the app sends its path as an `@`-reference, which is plain text every agent
/// either reads as an image or just sees as a path.
class AttachedImage {
  /// Downscales so the longest side is at most this, in pixels: phone photos are megabytes, and
  /// the agent downsamples past this anyway.
  static const maxSide = 1568;

  /// The image type of [bytes] by magic, or null when they are no PNG, JPEG, GIF or WebP image.
  static String? mimeOf(Uint8List bytes) {
    bool starts(List<int> magic) =>
        bytes.length >= magic.length &&
        magic.asMap().entries.every((e) => bytes[e.key] == e.value);
    if (starts(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])) return 'image/png';
    if (starts(const [0xFF, 0xD8, 0xFF])) return 'image/jpeg';
    if (starts(const [0x47, 0x49, 0x46, 0x38])) return 'image/gif'; // GIF8
    if (starts(const [0x52, 0x49, 0x46, 0x46]) &&
        bytes.length >= 12 &&
        bytes[8] == 0x57 &&
        bytes[9] == 0x45 &&
        bytes[10] == 0x42 &&
        bytes[11] == 0x50) {
      return 'image/webp'; // RIFF....WEBP
    }
    return null;
  }

  /// Runs [command], answering its stdout bytes, or null on any failure.
  static Future<Uint8List?> _tool(List<String> command) async {
    try {
      final result = await Process.run(command[0], command.sublist(1), stdoutEncoding: null);
      if (result.exitCode == 0 && (result.stdout as List<int>).isNotEmpty) {
        return Uint8List.fromList(result.stdout as List<int>);
      }
    } catch (_) {} // missing tool or no clipboard
    return null;
  }

  /// Picks an offered clipboard type to read image bytes from: a real image type first
  /// (`image/png` before the rest), else a typeless byte stream, whose magic is sniffed later.
  /// Some screenshot tools offer only `application/octet-stream`.
  static String? pickClipboardType(String types) {
    final offered = types.split('\n').map((t) => t.trim().toLowerCase()).toSet();
    for (final mime in const ['image/png', 'image/jpeg', 'image/webp', 'image/gif']) {
      if (offered.contains(mime)) return mime;
    }
    if (offered.contains('application/octet-stream')) return 'application/octet-stream';
    return null;
  }

  /// Reads an image from the desktop clipboard (`wl-paste`, else `xclip`), the same tools
  /// OpenCode reads on its host; null when there is no image (or neither tool). Desktop only:
  /// phones read images through the attach button's picker instead.
  static Future<Uint8List?> readClipboardImage() async {
    final wayland = await _tool(const ['wl-paste', '--list-types']);
    if (wayland != null) {
      final pick = pickClipboardType(String.fromCharCodes(wayland));
      if (pick != null) return _tool(['wl-paste', '-t', pick]);
      return null;
    }
    final x11 = await _tool(const ['xclip', '-selection', 'clipboard', '-t', 'TARGETS', '-o']);
    if (x11 != null) {
      final pick = pickClipboardType(String.fromCharCodes(x11));
      if (pick != null) return _tool(['xclip', '-selection', 'clipboard', '-t', pick, '-o']);
    }
    return null;
  }

  /// Returns [bytes] with its mime when they are an image fitting [maxSide], else a PNG scaled
  /// down to it. Throws when the bytes decode as no image; callers report that instead of
  /// uploading garbage.
  static Future<(Uint8List, String)> normalize(Uint8List bytes, {int maxSide = AttachedImage.maxSide}) async {
    final mime = mimeOf(bytes) ?? (throw StateError('Not a PNG, JPEG, GIF or WebP image.'));
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    final image = frame.image;
    try {
      if (max(image.width, image.height) <= maxSide) return (bytes, mime);
      final scale = maxSide / max(image.width, image.height);
      final width = (image.width * scale).round();
      final height = (image.height * scale).round();
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      canvas.drawImageRect(
        image,
        ui.Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
        ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
        ui.Paint()..filterQuality = ui.FilterQuality.medium,
      );
      final picture = recorder.endRecording();
      final scaled = await picture.toImage(width, height);
      try {
        final data = await scaled.toByteData(format: ui.ImageByteFormat.png);
        final png = data?.buffer.asUint8List();
        if (png == null || png.isEmpty) throw StateError('Could not encode the image as PNG.');
        return (png, 'image/png');
      } finally {
        scaled.dispose();
      }
    } finally {
      image.dispose();
    }
  }
}
