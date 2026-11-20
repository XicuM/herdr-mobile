// Talks to this machine's herdr-core (`herdr-core connect`), so it's skipped where there is none.
import "dart:io";
import "dart:typed_data";
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/services/hc.dart';
import 'package:herdr_mobile/services/pty_channel.dart';
import 'package:xterm/xterm.dart';

void main() {
  final local = Process.runSync('sh', ['-c', 'command -v herdr-core']).exitCode == 0;
  test('HcLink speaks herdr-core framed protocol', () async {
    final p = await Process.start('herdr-core', ['connect']);
    final link = HcLink(p.stdout.map((b) => b is Uint8List ? b : Uint8List.fromList(b)), p.stdin.add, p.kill,
        errors: p.stderr.map((b) => Uint8List.fromList(b)));
    await link.hello();
    expect(link.coreName, isNotEmpty);
    final list = await link.call('terminal.list') as Map;
    expect(list['terminals'], isA<List>());
    final snap = await link.subscribe((_) {});
    expect(snap['seq'], isA<int>());
    final doc = await link.call('doc.get', {'name': 'herdr-app'}) as Map;
    expect(doc.containsKey('version'), isTrue);
    final live = (list['terminals'] as List).firstWhere((t) => t['state'] == 'live');
    final attach = await link.call('terminal.attach', {'terminal': live['address'], 'cols': 40, 'rows': 10, 'observe': true}) as Map;
    final got = <int>[];
    link.listen(attach['channel'], (kind, payload) => got.addAll(payload));
    await Future.delayed(const Duration(milliseconds: 500));
    expect(got, isNotEmpty);
    await expectLater(link.call('terminal.get', {'terminal': 'zz9'}), throwsA(isA<HcError>().having((e) => e.kind, 'kind', 'not_found')));
    link.dispose();
  }, skip: !local);

  test('PtyChannel streams a terminal both ways and follows its size', () async {
    final p = await Process.start('herdr-core', ['connect']);
    final link = HcLink(p.stdout.map((b) => b is Uint8List ? b : Uint8List.fromList(b)), p.stdin.add, p.kill);
    await link.hello();
    // A terminal of its own, so nobody's real one is resized or typed into.
    final run = await link.call('terminal.run', {
      'argv': ['bash', '--norc', '-i'],
      'bg': true,
      'labels': {'herdr-mobile-test': '1'},
    }) as Map;
    final address = (run['terminal'] ?? run)['address'] as String;
    final terminal = Terminal()..resize(50, 12);
    final pty = PtyChannel(machine: 'local', paneId: address, terminal: terminal, link: () => link, address: address);
    try {
      await pty.connect();
      for (var i = 0; i < 50 && !pty.attached.value; i++) {
        await Future.delayed(const Duration(milliseconds: 50));
      }
      expect(pty.attached.value, isTrue);
      pty.sendInput('echo hc-\$((40+2))\r');
      String screen() => terminal.buffer.lines.toList().map((l) => l.getText()).join('\n');
      for (var i = 0; i < 60 && !screen().contains('hc-42'); i++) {
        await Future.delayed(const Duration(milliseconds: 50));
      }
      expect(screen(), contains('hc-42'));
      final got = await link.call('terminal.get', {'terminal': address}) as Map;
      expect((got['terminal'] ?? got)['cols'], 50); // the active viewer sets the size
      pty.sendResize(60, 15);
      await Future.delayed(const Duration(milliseconds: 300));
      final resized = await link.call('terminal.get', {'terminal': address}) as Map;
      expect((resized['terminal'] ?? resized)['cols'], 60);
    } finally {
      pty.dispose();
      await link.call('terminal.kill', {'terminal': address}).catchError((_) => null);
      link.dispose();
    }
  }, skip: !local);
}
