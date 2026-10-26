import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/services/attached_image.dart';

const pngMagic = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];

void main() {
  test('mimeOf sniffs image magics', () {
    expect(AttachedImage.mimeOf(Uint8List.fromList(pngMagic)), 'image/png');
    expect(AttachedImage.mimeOf(Uint8List.fromList(const [0xFF, 0xD8, 0xFF, 0x00])), 'image/jpeg');
    expect(AttachedImage.mimeOf(Uint8List.fromList(const [0x47, 0x49, 0x46, 0x38, 0x39, 0x61])), 'image/gif');
    expect(
        AttachedImage.mimeOf(Uint8List.fromList(const [0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0, 0x57, 0x45, 0x42, 0x50])),
        'image/webp');
    expect(AttachedImage.mimeOf(Uint8List.fromList(const [0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0, 0x4A, 0x50, 0x45, 0x47])),
        isNull);
    expect(AttachedImage.mimeOf(Uint8List.fromList('hello'.codeUnits)), isNull);
    expect(AttachedImage.mimeOf(Uint8List(0)), isNull);
  });

  test('uploadable sends an image as it came', () {
    final png = Uint8List.fromList(pngMagic);
    expect(AttachedImage.uploadable(png), (png, 'image/png'));
  });

  test('uploadable refuses what the bridge would', () {
    final big = Uint8List(AttachedImage.maxBytes + 1)..setAll(0, pngMagic);
    expect(() => AttachedImage.uploadable(big), throwsStateError);
    expect(() => AttachedImage.uploadable(Uint8List.fromList('hello'.codeUnits)), throwsStateError);
  });

  test('pickClipboardType prefers images, then typeless bytes', () {
    expect(AttachedImage.pickClipboardType('text/plain;charset=utf-8\nimage/png\nTEXT'), 'image/png');
    expect(AttachedImage.pickClipboardType('image/jpeg\nimage/png'), 'image/png');
    expect(AttachedImage.pickClipboardType('application/octet-stream'), 'application/octet-stream');
    expect(AttachedImage.pickClipboardType('text/plain;charset=utf-8'), isNull);
    expect(AttachedImage.pickClipboardType(''), isNull);
  });

  test('formatReference formats for each agent', () {
    expect(AttachedImage.formatReference('codex', 'img.png'), 'img.png ');
    expect(AttachedImage.formatReference('codex', 'my img.png'), '"my img.png" ');
    expect(AttachedImage.formatReference('agy', 'img.png'), '@img.png ');
    expect(AttachedImage.formatReference('copilot', 'img.png'), '@img.png ');
    expect(AttachedImage.formatReference('grok', 'img.png'), '@img.png ');
    expect(AttachedImage.formatReference('opencode', 'img.png'), '@img.png ');
    expect(AttachedImage.formatReference('pi', 'img.png'), '@img.png ');
    expect(AttachedImage.formatReference('pi', 'my img.png'), '@"my img.png" ');
    expect(AttachedImage.formatReference('claude', 'img.png'), '@img.png ');
    expect(AttachedImage.formatReference('claude', 'my img.png'), '@"my img.png" ');
    expect(AttachedImage.formatReference(null, 'img.png'), '@img.png ');
    expect(AttachedImage.formatReference('unknown', 'img.png'), '@img.png ');
  });
}
