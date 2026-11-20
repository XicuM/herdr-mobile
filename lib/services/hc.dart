import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:pinenacl/ed25519.dart' as ed25519;

/// herdr-core's API failed: its `data.kind` (`not_found`, `unavailable`…) and message.
class HcError implements Exception {
  HcError(this.kind, this.message);
  final String kind, message;
  @override
  String toString() => message;
}

/// This phone's SSH key: made once, kept in prefs as OpenSSH PEM.
class PhoneKey {
  PhoneKey._(this.pair, this.publicLine);
  final SSHKeyPair pair;

  /// For the machine's `~/.ssh/authorized_keys`.
  final String publicLine;

  static PhoneKey fromPem(String pem) {
    final pair = SSHKeyPair.fromPem(pem).single;
    return PhoneKey._(pair, 'ssh-ed25519 ${base64.encode(pair.toPublicKey().encode())} herdr-mobile');
  }

  static String generatePem() {
    final key = ed25519.SigningKey.generate();
    return OpenSSHEd25519KeyPair(key.verifyKey.asTypedList, key.asTypedList, 'herdr-mobile').toPem();
  }
}

/// One SSH connection to a machine's herdr-core (`herdr-core connect`, as herdr-core dials its own
/// machines), in framed mode: JSON-RPC on channel 0, and an event or terminal stream on each other.
/// Every frame is `[channel u32 LE][kind u8][len u32 LE][payload]` (herdr-core `schema/README.md`).
class HcLink {
  /// Speaks over [output] (what the core writes) and [write] (to it); [close] ends the transport.
  HcLink(Stream<Uint8List> output, this._write, this._close, {Stream<Uint8List>? errors}) {
    final err = StringBuffer();
    errors?.listen((b) => err.write(utf8.decode(b, allowMalformed: true)));
    output.listen(_read, onDone: () => _drop(err.toString().trim()), onError: (e) => _drop('$e'));
  }

  /// herdr-core's own line for reaching itself over SSH: it may not be on a non-login shell's PATH.
  static const _line = "sh -c 'p=\$(command -v herdr-core) || p=\$HOME/.local/bin/herdr-core; "
      "[ -x \"\$p\" ] || { echo \"herdr-core is not installed here\" >&2; exit 127; }; exec \"\$p\" connect'";

  static const data = 0, credit = 1, close = 2, resize = 3;

  final void Function(Uint8List) _write;
  final void Function() _close;
  final _calls = <int, Completer<dynamic>>{};
  final _streams = <int, void Function(int kind, Uint8List payload)>{};
  final _early = <int, List<(int, Uint8List)>>{};
  var _id = 0;
  final _buf = BytesBuilder(copy: false);
  final _done = Completer<String?>();

  /// The core's name for itself, from `hello`.
  late final String coreName;

  /// Completes when the link drops, with why when known.
  Future<String?> get done => _done.future;

  /// Dials [target] (`user@host` or `user@host:port`), checks its host key with [verifyHostKey] (a
  /// hex fingerprint), logs in with [key] (or none, as Tailscale SSH takes), and says hello.
  static Future<HcLink> open(String target, PhoneKey? key, FutureOr<bool> Function(String fingerprint) verifyHostKey) async {
    final at = target.lastIndexOf('@');
    final hostPort = target.substring(at + 1);
    final colon = hostPort.lastIndexOf(':');
    final host = colon > 0 ? hostPort.substring(0, colon) : hostPort;
    final port = colon > 0 ? int.tryParse(hostPort.substring(colon + 1)) ?? 22 : 22;
    final socket = await SSHSocket.connect(host, port, timeout: const Duration(seconds: 10));
    final ssh = SSHClient(
      socket,
      username: at > 0 ? target.substring(0, at) : '',
      identities: key == null ? null : [key.pair],
      onVerifyHostKey: (_, fp) => verifyHostKey(fp.map((b) => b.toRadixString(16).padLeft(2, '0')).join(':')),
      keepAliveInterval: const Duration(seconds: 20),
    );
    final session = await ssh.execute(_line);
    final link = HcLink(session.stdout, session.write, () {
      session.close();
      ssh.close();
    }, errors: session.stderr);
    ssh.done.then((_) => link._drop(null), onError: (e) => link._drop('$e'));
    await link.hello();
    return link;
  }

  /// Plain mode until hello's reply, which switches the connection to framed.
  Future<void> hello() async {
    _calls[0] = Completer();
    _write(utf8.encode('${jsonEncode({
          'jsonrpc': '2.0',
          'id': 0,
          'method': 'hello',
          'params': {'generation': 1, 'framed': true},
        })}\n'));
    final hello = await _calls[0]!.future.timeout(const Duration(seconds: 15));
    coreName = hello['core']?['name'] ?? '';
  }

  bool _framed = false;

  void _read(Uint8List bytes) {
    _buf.add(bytes);
    var all = _buf.takeBytes();
    var at = 0;
    if (!_framed) {
      final nl = all.indexOf(10);
      if (nl < 0) return _buf.add(all);
      _framed = true;
      _message(utf8.decode(all.sublist(0, nl)));
      at = nl + 1;
    }
    while (all.length - at >= 9) {
      final head = ByteData.sublistView(all, at, at + 9);
      final len = head.getUint32(5, Endian.little);
      if (all.length - at - 9 < len) break;
      final channel = head.getUint32(0, Endian.little);
      final payload = Uint8List.sublistView(all, at + 9, at + 9 + len);
      at += 9 + len;
      if (channel == 0) {
        _message(utf8.decode(payload));
      } else {
        final kind = head.getUint8(4);
        final on = _streams[channel];
        // A stream's first frames can come with the reply that opens it, before anyone listens.
        on != null ? on(kind, payload) : (_early[channel] ??= []).add((kind, Uint8List.fromList(payload)));
      }
    }
    if (at < all.length) _buf.add(Uint8List.fromList(all.sublist(at)));
  }

  void _message(String text) {
    final msg = jsonDecode(text);
    final c = _calls.remove(msg['id']);
    if (c == null) return;
    final e = msg['error'];
    e == null ? c.complete(msg['result']) : c.completeError(HcError('${e['data']?['kind'] ?? ''}', '${e['message']}'));
  }

  void _drop(String? why) {
    if (_done.isCompleted) return;
    _done.complete(why == null || why.isEmpty ? null : why);
    for (final c in _calls.values) {
      c.completeError(HcError('unavailable', why ?? 'Connection lost'));
    }
    _calls.clear();
    for (final s in _streams.values.toList()) {
      s(close, Uint8List(0));
    }
    _streams.clear();
  }

  void send(int channel, int kind, List<int> payload) {
    if (_done.isCompleted) return;
    final head = ByteData(9)
      ..setUint32(0, channel, Endian.little)
      ..setUint8(4, kind)
      ..setUint32(5, payload.length, Endian.little);
    _write(Uint8List.fromList([...head.buffer.asUint8List(), ...payload]));
  }

  /// One API call ([herdr-core's methods](https://github.com/herdrdev/herdr-core/blob/master/schema/hc.openrpc.json)).
  Future<dynamic> call(String method, [Map<String, dynamic> params = const {}]) {
    if (_done.isCompleted) return Future.error(HcError('unavailable', 'Not connected'));
    final id = ++_id;
    final c = _calls[id] = Completer();
    send(0, data, utf8.encode(jsonEncode({'jsonrpc': '2.0', 'id': id, 'method': method, 'params': params})));
    return c.future;
  }

  /// Takes [channel]'s frames (its DATA, RESIZE and CLOSE) until it closes.
  void listen(int channel, void Function(int kind, Uint8List payload) onFrame) {
    _streams[channel] = onFrame;
    for (final (kind, payload) in _early.remove(channel) ?? const <(int, Uint8List)>[]) {
      onFrame(kind, payload);
    }
  }

  void forget(int channel) {
    _streams.remove(channel);
    _early.remove(channel);
  }

  /// `events.subscribe`: its reply (`seq`, `terminals`), then each notification (`event`, `heartbeat`,
  /// `missed`) to [onNotification], as JSON lines on a channel of its own, with credit.
  Future<Map> subscribe(void Function(Map notification) onNotification) async {
    final res = await call('events.subscribe') as Map;
    final channel = res['channel'] as int;
    var partial = '';
    listen(channel, (kind, payload) {
      if (kind != data) return;
      final lines = (partial + utf8.decode(payload, allowMalformed: true)).split('\n');
      partial = lines.removeLast();
      for (final line in lines) {
        if (line.isNotEmpty) onNotification(jsonDecode(line));
      }
      send(channel, credit, (ByteData(4)..setUint32(0, payload.length, Endian.little)).buffer.asUint8List());
    });
    return res;
  }

  void dispose() {
    _drop(null);
    _close();
  }
}
