import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:syncnotes/api.dart';
import 'package:syncnotes/crypto.dart';

void main() {
  final bin = Platform.environment['SYNCNOTES_SERVER_BIN'];
  test('encrypted note and file roundtrip against the server', () async {
    if (bin == null) return;
    final dir = await Directory.systemTemp.createTemp('sn-e2e');
    final port = 18000 + (DateTime.now().millisecondsSinceEpoch % 2000);
    final addr = '127.0.0.1:$port';
    final server = await Process.start(bin, ['--bind', addr, '--db', '${dir.path}/t.db', '--files-dir', '${dir.path}/files', '--allow-register', 'true']);
    addTearDown(() {
      server.kill();
      dir.delete(recursive: true);
    });
    final api = SyncApi();
    var up = false;
    for (var i = 0; i < 40; i++) {
      try {
        final r = await api.client.get(SyncApi.endpoint(addr, '/health'));
        if (r.statusCode == 200) {
          up = true;
          break;
        }
      } catch (_) {}
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    expect(up, isTrue);
    final session = await api.register('http://$addr', 'bill', 'secret1');
    final box = await NoteCipher.fromPassword('secret1', memoryKiB: 32, iterations: 1);
    final sealed = await box.sealText('{"title":"t","body":"hello","files":[]}');
    await api.putNote(addr, session.token, RemoteNote(id: 'n1', updatedAt: 5, nonce: sealed.nonce, ciphertext: sealed.ciphertext));
    final notes = await api.notes(addr, session.token);
    expect(notes, hasLength(1));
    expect(await box.openText(notes.single.nonce, notes.single.ciphertext), contains('hello'));

    final plain = List<int>.generate(40, (i) => i);
    final sealedFile = File('${dir.path}/in.bin');
    await sealedFile.writeAsBytes(await box.sealBytes(plain, chunk: 16));
    final upFile = await api.uploadFile(addr, session.token, sealedFile, name: 'a.txt');
    final out = File('${dir.path}/out.bin');
    await api.downloadTo(addr, session.token, upFile.id, out);
    expect(await box.openBytes(await out.readAsBytes()), plain);
  }, skip: bin == null ? 'SYNCNOTES_SERVER_BIN is not set' : false);
}
