import 'package:flutter_test/flutter_test.dart';
import 'package:syncnotes/blocks/builtin_types.dart';
import 'package:syncnotes/models/block.dart';
import 'package:syncnotes/services/auth_api.dart';

void main() {
  test('shortTitle does not split emoji', () {
    final t = shortTitle('${'a' * 39}😀😀😀');
    expect(t, '${'a' * 39}😀…');
    expect(shortTitle('第一行\n第二行'), '第一行');
  });

  test('safeFileName blocks path traversal and illegal chars', () {
    expect(safeFileName('../../etc/passwd'), 'passwd');
    expect(safeFileName(r'..\\..\\win.ini'), 'win.ini');
    expect(safeFileName('a<b>c?.txt'), 'a_b_c_.txt');
    expect(safeFileName('...'), 'file');
    expect(safeFileName('CON.txt'), '_CON.txt');
    expect(safeFileName('报告.pdf'), '报告.pdf');
  });

  test('API endpoints keep reverse-proxy prefix', () {
    expect(AuthApi.endpoint('https://h.com/notes', '/api/login').toString(), 'https://h.com/notes/api/login');
    expect(AuthApi.endpoint('192.168.1.2:7700', '/api/login').toString(), 'http://192.168.1.2:7700/api/login');
    expect(AuthApi.endpoint('wss://h.com/notes/ws', '/api/files', {'name': 'a'}).toString(),
        'https://h.com/notes/api/files?name=a');
  });
}
