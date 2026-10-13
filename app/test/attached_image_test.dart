import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/services/attached_image.dart';

/// A w×h red PNG, built with the engine so the tests need no assets.
Future<Uint8List> testPng(int w, int h) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawRect(
    ui.Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
    ui.Paint()..color = const ui.Color(0xFFFF0000),
  );
  final image = await recorder.endRecording().toImage(w, h);
  try {
    return (await image.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
  } finally {
    image.dispose();
  }
}

Future<(int, int)> sizeOf(Uint8List png) async {
  final frame = await (await ui.instantiateImageCodec(png)).getNextFrame();
  try {
    return (frame.image.width, frame.image.height);
  } finally {
    frame.image.dispose();
  }
}

void main() {
  test('mimeOf sniffs image magics', () {
    expect(AttachedImage.mimeOf(Uint8List.fromList(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])), 'image/png');
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

  test('normalize keeps small images byte-identical', () async {
    final png = await testPng(60, 40);
    expect(await AttachedImage.normalize(png, maxSide: 1568), (png, 'image/png'));
  });

  test('normalize shrinks past the limit, keeping aspect', () async {
    final png = await testPng(100, 40);
    final (bytes, mime) = await AttachedImage.normalize(png, maxSide: 50);
    expect(mime, 'image/png');
    expect(bytes, isNot(equals(png)));
    expect(await sizeOf(bytes), (50, 20));
  });

  test('normalize rejects non-images', () async {
    await expectLater(AttachedImage.normalize(Uint8List.fromList('hello'.codeUnits)), throwsStateError);
  });

  test('pickClipboardType prefers images, then typeless bytes', () {
    expect(AttachedImage.pickClipboardType('text/plain;charset=utf-8\nimage/png\nTEXT'), 'image/png');
    expect(AttachedImage.pickClipboardType('image/jpeg\nimage/png'), 'image/png');
    expect(AttachedImage.pickClipboardType('application/octet-stream'), 'application/octet-stream');
    expect(AttachedImage.pickClipboardType('text/plain;charset=utf-8'), isNull);
    expect(AttachedImage.pickClipboardType(''), isNull);
  });
}
