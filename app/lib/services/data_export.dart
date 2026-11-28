import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

/// 「导出我的数据」：把本地缓存打包成 zip（JSON + Markdown + 已缓存的附件）。
/// 不依赖服务器，服务器丢失时也能救出数据。格式与服务器 `admin export` 相近。

/// 读取某个文件块的附件内容（本地已下载的副本或在线下载）；拿不到返回 null。
typedef AttachmentReader =
    Future<List<int>?> Function(Map<String, dynamic> block);

String exportSafeName(String s) {
  var n = s.replaceAll(RegExp(r'[/\\:*?"<>|\x00-\x1f]'), '_').trim();
  n = n.replaceAll(RegExp(r'^\.+|\.+$'), '');
  if (n.characters.length > 80) n = n.characters.take(80).toString();
  return n.isEmpty ? 'untitled' : n;
}

extension on String {
  _Chars get characters => _Chars(this);
}

class _Chars {
  final String s;
  _Chars(this.s);
  int get length => s.runes.length;
  _Chars take(int n) => _Chars(String.fromCharCodes(s.runes.take(n)));
  @override
  String toString() => s;
}

double _order(Map<String, dynamic> b) =>
    ((b['payload'] as Map?)?['order'] as num?)?.toDouble() ??
    (b['created_at'] as num? ?? 0).toDouble();

String _str(Map? p, String k) => (p?[k] ?? '').toString();

void _renderMd(
  Map<String, dynamic> b,
  Map<String, List<Map<String, dynamic>>> kids,
  Map<String, String> files,
  int depth,
  Set<String> visited,
  StringBuffer out,
  String linkPrefix,
) {
  final id = (b['id'] ?? '').toString();
  if (depth > 128 || (id.isNotEmpty && !visited.add(id))) return;
  final p = (b['payload'] as Map?) ?? const {};
  final title = (b['title'] ?? '').toString();
  final text = _str(p, 'text').isNotEmpty
      ? _str(p, 'text')
      : _str(p, 'markdown');
  final ind = '  ' * (depth > 0 ? depth - 1 : 0);
  if (depth == 0) {
    final icon = _str(p, 'icon');
    out.writeln(
      '# ${icon.isEmpty ? '' : '$icon '}${title.isEmpty ? '无标题' : title}\n',
    );
    if (b['deleted_at'] != null) out.writeln('> 回收站项目\n');
    if (text.isNotEmpty) out.writeln('$text\n');
  } else if (files.containsKey(b['id'])) {
    final name = _str(p, 'name').isEmpty ? title : _str(p, 'name');
    out.writeln('$ind[📎 $name]($linkPrefix${files[b['id']]})\n');
  } else {
    final line = switch (_str(p, 'type')) {
      'h1' => '## $text',
      'h2' => '### $text',
      'h3' => '#### $text',
      'bullet' => '$ind- $text',
      'numbered' => '${ind}1. $text',
      'todo' => '$ind- [${p['checked'] == true ? 'x' : ' '}] $text',
      'toggle' => '$ind▸ $text',
      'quote' => '> $text',
      'callout' =>
        '> ${_str(p, 'icon').isEmpty ? '💡' : _str(p, 'icon')} $text',
      'code' => '```${_str(p, 'lang')}\n$text\n```',
      'divider' => '---',
      'image' when _str(p, 'url').isNotEmpty =>
        '$ind![${text.isEmpty ? 'image' : text}](${_str(p, 'url')})',
      _ when b['kind'] == 'page' || b['kind'] == 'folder' =>
        '$ind- 📄 ${title.isEmpty ? '无标题' : title}',
      _ => '$ind${text.isEmpty ? title : text}',
    };
    out.writeln('$line\n');
  }
  for (final c in kids[b['id']] ?? const <Map<String, dynamic>>[]) {
    _renderMd(c, kids, files, depth + 1, visited, out, linkPrefix);
  }
}

class LocalExportResult {
  final Uint8List bytes;
  final int blocks, trashed, files, missingFiles, pending;
  LocalExportResult(
    this.bytes,
    this.blocks,
    this.trashed,
    this.files,
    this.missingFiles,
    this.pending,
  );
}

/// `cache` 为本地缓存快照（LocalStore 中保存的 {blocks, outbox, last_seq}）。
Future<LocalExportResult> buildLocalExport({
  required Map<String, dynamic> cache,
  String? username,
  String? server,
  AttachmentReader? readAttachment,
  DateTime? now,
  String source = 'client-cache',
  int formatVersion = 1,
}) async {
  final all = [
    for (final b in (cache['blocks'] as List? ?? const []))
      Map<String, dynamic>.from(b as Map),
  ];
  final live = all.where((b) => b['deleted'] != true).toList();
  final trashed = live.where((b) => b['deleted_at'] != null).length;
  final outbox = (cache['outbox'] as List?) ?? const [];
  final archive = Archive();
  void add(String name, List<int> data) =>
      archive.addFile(ArchiveFile(name, data.length, data));
  const enc = JsonEncoder.withIndent('  ');

  // 附件
  final files = <String, String>{};
  var missing = 0;
  for (final b in live) {
    final p = (b['payload'] as Map?) ?? const {};
    final fid = _str(p, 'file_id');
    if (fid.isEmpty) continue;
    List<int>? data;
    try {
      data = await readAttachment?.call(b);
    } catch (_) {}
    if (data == null) {
      missing++;
      continue;
    }
    final name = _str(p, 'name').isEmpty
        ? (b['title'] ?? fid).toString()
        : _str(p, 'name');
    final rel =
        'files/${fid.length > 8 ? fid.substring(0, 8) : fid}-${exportSafeName(name)}';
    add(rel, data);
    files[b['id'] as String] = rel;
  }

  add(
    'manifest.json',
    utf8.encode(
      enc.convert({
        'format': 'syncnotes-export',
        'version': formatVersion,
        'source': source,
        'username': username,
        'server': server,
        'exported_at': (now ?? DateTime.now()).toUtc().toIso8601String(),
        'blocks': all.length,
        'live_blocks': live.length,
        'trashed_blocks': trashed,
        'files': files.length,
        'missing_files': missing,
        'pending_changes': outbox.length,
        'last_seq': cache['last_seq'],
      }),
    ),
  );
  add('blocks.json', utf8.encode(enc.convert(all)));
  // 尚未同步到服务器的修改也一起导出，避免丢失
  add('pending_outbox.json', utf8.encode(enc.convert(outbox)));

  // Markdown
  final ids = {for (final b in live) b['id']};
  final kids = <String, List<Map<String, dynamic>>>{};
  final roots = <Map<String, dynamic>>[];
  for (final b in live) {
    final pid = b['parent_id'];
    if (pid != null && pid != b['id'] && ids.contains(pid)) {
      kids.putIfAbsent(pid as String, () => []).add(b);
    } else {
      roots.add(b);
    }
  }
  for (final l in kids.values) {
    l.sort((a, b) => _order(a).compareTo(_order(b)));
  }
  roots.sort(
    (a, b) => ((a['created_at'] as num?) ?? 0).compareTo(
      (b['created_at'] as num?) ?? 0,
    ),
  );
  final used = <String, int>{};
  for (final r in roots) {
    final inTrash = r['deleted_at'] != null;
    final dir = inTrash ? 'markdown/回收站' : 'markdown';
    final title = (r['title'] ?? '').toString();
    final base =
        '$dir/${exportSafeName(title.isEmpty ? r['id'].toString() : title)}';
    final n = used[base] = (used[base] ?? 0) + 1;
    final out = StringBuffer();
    final visited = <String>{};
    _renderMd(r, kids, files, 0, visited, out, inTrash ? '../../' : '../');
    add(n == 1 ? '$base.md' : '$base ($n).md', utf8.encode(out.toString()));
  }
  final bytes = ZipEncoder().encodeBytes(archive);
  return LocalExportResult(
    Uint8List.fromList(bytes),
    all.length,
    trashed,
    files.length,
    missing,
    outbox.length,
  );
}

class BackupInfo {
  final String format;
  final int version;
  final String? source;
  final String? username;
  final String? exportedAt;
  final int blocks;
  final int files;
  final int pending;
  const BackupInfo({
    required this.format,
    required this.version,
    this.source,
    this.username,
    this.exportedAt,
    this.blocks = 0,
    this.files = 0,
    this.pending = 0,
  });

  bool get supported =>
      format == 'syncnotes-export' || format == 'syncnotes-backup';
}

BackupInfo inspectBackup(List<int> bytes) {
  final z = ZipDecoder().decodeBytes(bytes);
  final f = z.findFile('manifest.json');
  if (f == null) {
    throw const FormatException('备份缺少 manifest.json，不是 SyncNotes 备份');
  }
  final blocksFile = z.findFile('blocks.json');
  if (blocksFile == null) {
    throw const FormatException('备份缺少 blocks.json，不是 SyncNotes 备份');
  }
  final m = jsonDecode(utf8.decode(f.content as List<int>));
  if (m is! Map) throw const FormatException('manifest.json 格式错误');
  final format = (m['format'] ?? '').toString();
  if (format != 'syncnotes-export' && format != 'syncnotes-backup') {
    throw FormatException('无法识别的备份格式：$format');
  }
  final pendingFile = z.findFile('pending_outbox.json');
  var pending = 0;
  if (pendingFile != null) {
    final p = jsonDecode(utf8.decode(pendingFile.content as List<int>));
    if (p is List) pending = p.length;
  }
  return BackupInfo(
    format: format,
    version: (m['version'] as num?)?.toInt() ?? 1,
    source: m['source'] as String?,
    username: m['username'] as String?,
    exportedAt: m['exported_at'] as String?,
    blocks:
        (m['blocks'] as num?)?.toInt() ??
        (jsonDecode(utf8.decode(blocksFile.content as List<int>)) as List)
            .length,
    files: (m['files'] as num?)?.toInt() ?? 0,
    pending: pending,
  );
}

List<Map<String, dynamic>> applyOutboxToBlocks(
  List<Map<String, dynamic>> blocks,
  List outbox,
) {
  final out = [for (final b in blocks) Map<String, dynamic>.from(b)];
  for (final raw in outbox) {
    if (raw is! Map) continue;
    final op = Map<String, dynamic>.from(raw);
    if (op['type'] != 'upsert_block') continue;
    final id = (op['id'] ?? '').toString();
    if (id.isEmpty) continue;
    final block = Map<String, dynamic>.from(op);
    if (op['client_updated_at'] != null) {
      block['updated_at'] = op['client_updated_at'];
    }
    block.remove('type');
    block.remove('client_updated_at');
    final i = out.indexWhere((b) => b['id'] == id);
    if (i >= 0) {
      out[i] = {...out[i], ...block};
    } else {
      out.add(block);
    }
  }
  return out;
}

/// 把服务器导出的 zip 与本机尚未同步的修改、本机独有附件合并成一份完整备份。
Uint8List mergeBackupWithLocal({
  required List<int> serverZip,
  required Map<String, dynamic> cache,
  Map<String, List<int>> extraFiles = const {},
  String? username,
  String? server,
  DateTime? now,
}) {
  final z = ZipDecoder().decodeBytes(serverZip);
  if (z.findFile('manifest.json') == null ||
      z.findFile('blocks.json') == null) {
    throw const FormatException('服务器备份缺少必要文件');
  }
  final oldBlocks =
      (jsonDecode(utf8.decode(z.findFile('blocks.json')!.content as List<int>))
              as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
  final outbox = (cache['outbox'] as List?) ?? const [];
  final mergedBlocks = applyOutboxToBlocks(oldBlocks, outbox);
  final archive = Archive();
  void add(String name, List<int> data) =>
      archive.addFile(ArchiveFile(name, data.length, data));

  final existingFiles = <String>{};
  for (final f in z.files) {
    if (!f.isFile) continue;
    if (f.name == 'manifest.json' ||
        f.name == 'blocks.json' ||
        f.name == 'pending_outbox.json') {
      continue;
    }
    final bytes = f.content as List<int>;
    add(f.name, bytes);
    if (f.name.replaceAll('\\', '/').startsWith('files/')) {
      existingFiles.add(f.name.replaceAll('\\', '/'));
    }
  }

  for (final e in extraFiles.entries) {
    final fid = e.key;
    if (fid.isEmpty) continue;
    final already = existingFiles.any(
      (n) => n.contains(fid.substring(0, fid.length < 8 ? fid.length : 8)),
    );
    if (already) continue;
    final rel =
        'files/${fid.length > 8 ? fid.substring(0, 8) : fid}-${exportSafeName(fid)}';
    add(rel, e.value);
    existingFiles.add(rel);
  }

  const enc = JsonEncoder.withIndent('  ');
  final live = mergedBlocks.where((b) => b['deleted'] != true).toList();
  final trashed = live.where((b) => b['deleted_at'] != null).length;
  add(
    'manifest.json',
    utf8.encode(
      enc.convert({
        'format': 'syncnotes-export',
        'version': 2,
        'source': 'client-backup',
        'username': username,
        'server': server,
        'exported_at': (now ?? DateTime.now()).toUtc().toIso8601String(),
        'blocks': mergedBlocks.length,
        'live_blocks': live.length,
        'trashed_blocks': trashed,
        'files': existingFiles.length,
        'pending_changes': outbox.length,
        'last_seq': cache['last_seq'],
      }),
    ),
  );
  add('blocks.json', utf8.encode(enc.convert(mergedBlocks)));
  add('pending_outbox.json', utf8.encode(enc.convert(outbox)));
  return Uint8List.fromList(ZipEncoder().encodeBytes(archive));
}
