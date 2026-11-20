import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/services/hc.dart';

void main() {
  test("The phone's key is an OpenSSH ed25519 key that loads back", () {
    final pem = PhoneKey.generatePem();
    final key = PhoneKey.fromPem(pem);
    expect(key.publicLine, startsWith('ssh-ed25519 '));
    expect(PhoneKey.fromPem(pem).publicLine, key.publicLine);
    final out = Platform.environment['HC_KEY_OUT'];
    if (out != null) {
      File('$out/id').writeAsStringSync(pem);
      File('$out/id.pub').writeAsStringSync('${key.publicLine}\n');
    }
  });
}
