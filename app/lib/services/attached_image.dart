import 'dart:io' show Process;
import 'dart:typed_data';

/// An image picked or pasted for an agent: the bridge saves it where that agent runs and the app
/// sends its path as an `@`-reference, which is plain text every agent either reads as an image or
/// just sees as a path.
class AttachedImage {
  /// The bridge's cap on one upload (`uploads::MAX_BYTES`). Nothing here shrinks an image to fit it:
  /// the engine can only re-encode PNG, which for a photo is bigger than the JPEG it came from, and
  /// the agent downsamples what it reads anyway. An image this big is refused instead.
  static const maxBytes = 10 * 1024 * 1024;

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
      if (pick != null) return _image(await _tool(['wl-paste', '-t', pick]));
      return null;
    }
    final x11 = await _tool(const ['xclip', '-selection', 'clipboard', '-t', 'TARGETS', '-o']);
    if (x11 != null) {
      final pick = pickClipboardType(String.fromCharCodes(x11));
      if (pick != null) return _image(await _tool(['xclip', '-selection', 'clipboard', '-t', pick, '-o']));
    }
    return null;
  }

  /// [bytes] when they are an image, else null: an `application/octet-stream` offer can be anything,
  /// and what isn't an image is left to the field's own paste.
  static Uint8List? _image(Uint8List? bytes) => bytes != null && mimeOf(bytes) != null ? bytes : null;

  /// [bytes] as they are, with their mime: what was copied is what the agent gets to read, at the
  /// size it was copied. Throws when they are no PNG, JPEG, GIF or WebP image, or bigger than the
  /// bridge takes, which callers report instead of uploading.
  static (Uint8List, String) uploadable(Uint8List bytes) {
    final mime = mimeOf(bytes) ?? (throw StateError('Not a PNG, JPEG, GIF or WebP image.'));
    if (bytes.length > maxBytes) throw StateError('Image is over 10 MB.');
    return (bytes, mime);
  }
}
