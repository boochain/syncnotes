import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:syncnotes/services/settings.dart';
import 'package:syncnotes/sync/wire_seal.dart';

class _Health extends http.BaseClient {
  _Health(this.pub);
  final Uint8List pub;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final body = utf8.encode(jsonEncode({'seal_pub': base64.encode(pub)}));
    return http.StreamedResponse(Stream.value(body), 200);
  }
}

void main() {
  test('changed server key is refused until the saved fingerprint is cleared', () async {
    SharedPreferences.setMockInitialValues({});
    final settings = await Settings.load();
    const server = 'http://127.0.0.1:9';
    final first = Uint8List(32)..[0] = 1;
    final next = Uint8List(32)..[0] = 2;

    await WireSeal.serverPublic(server, pins: settings, client: _Health(first));
    expect(settings.sealPin(server), startsWith('01'));

    // 进程重启后内存缓存没了，磁盘上的旧指纹还在。
    WireSeal.forget(server);
    await expectLater(
      WireSeal.serverPublic(server, pins: settings, client: _Health(next)),
      throwsA(isA<SealPinMismatch>()),
    );
    expect(settings.sealPin(server), startsWith('01'));

    settings.clearSealPin(server);
    WireSeal.forget(server);
    await WireSeal.serverPublic(server, pins: settings, client: _Health(next));
    expect(settings.sealPin(server), startsWith('02'));
  });
}
