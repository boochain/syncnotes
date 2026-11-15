import 'dart:convert';
import 'dart:io';

/// 本地持久化：块缓存 + 离线队列 + 最后同步序号。
abstract class LocalStore {
  Future<Map<String, dynamic>?> load();
  Future<void> save(Map<String, dynamic> data);
}

class MemoryStore implements LocalStore {
  Map<String, dynamic>? data;
  @override
  Future<Map<String, dynamic>?> load() async => data;
  @override
  Future<void> save(Map<String, dynamic> d) async =>
      data = jsonDecode(jsonEncode(d)) as Map<String, dynamic>;
}

class FileStore implements LocalStore {
  final File file;
  FileStore(this.file);

  @override
  Future<Map<String, dynamic>?> load() async {
    try {
      if (!await file.exists()) return null;
      return jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  Future<void> _chain = Future.value();
  String? _latest;
  bool _scheduled = false;

  /// 串行化写入并合并频繁的保存请求（只写最新快照），避免临时文件竞争。
  @override
  Future<void> save(Map<String, dynamic> data) {
    _latest = jsonEncode(data);
    if (_scheduled) return _chain;
    _scheduled = true;
    _chain = _chain.then((_) async {
      _scheduled = false;
      final snapshot = _latest!;
      try {
        await file.parent.create(recursive: true);
        final tmp = File('${file.path}.tmp');
        await tmp.writeAsString(snapshot, flush: true);
        await tmp.rename(file.path);
      } catch (_) {
        // 写缓存失败不影响同步（下次保存会重试）
      }
    });
    return _chain;
  }
}
