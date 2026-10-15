import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';

import '../app_scope.dart';
import '../models/block.dart';
import '../ui/folder_page.dart';
import '../ui/note_editor_page.dart';
import 'block_type.dart';

void registerBuiltinTypes() {
  BlockTypes.register(MessageType());
  BlockTypes.register(NoteType());
  BlockTypes.register(FileType_());
  BlockTypes.register(FolderType());
  BlockTypes.register(UnknownType());
}

void _toast(BuildContext context, String msg) {
  ScaffoldMessenger.maybeOf(context)
    ?..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating));
}

// ------------------------------------------------------------------ message

class MessageType extends BlockType {
  @override
  BlockKind get kind => BlockKind.message;
  @override
  String get label => '消息';
  @override
  IconData get icon => Icons.chat_bubble_outline;
  @override
  Color color(ColorScheme cs) => cs.primary;
  @override
  String get executeLabel => '复制';

  static String textOf(Block b) => (b.payload['text'] ?? '') as String;

  @override
  Widget buildPreview(BuildContext context, Block block) => Text(
        textOf(block),
        maxLines: 4,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.bodyMedium,
      );

  @override
  Future<void> execute(BuildContext context, Block block) async {
    final sync = AppScope.of(context).sync;
    await Clipboard.setData(ClipboardData(text: textOf(block)));
    sync.setViewed(block.id, true);
    if (context.mounted) _toast(context, '已复制到剪贴板');
  }

  @override
  Future<bool> edit(BuildContext context, Block? block, {String? parentId}) async {
    final ctrl = TextEditingController(text: block == null ? '' : textOf(block));
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(block == null ? '新消息' : '编辑消息'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          minLines: 2,
          maxLines: 8,
          decoration: const InputDecoration(hintText: '输入消息内容', border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('发送')),
        ],
      ),
    );
    if (ok != true || ctrl.text.trim().isEmpty || !context.mounted) return false;
    final sync = AppScope.of(context).sync;
    final text = ctrl.text.trim();
    final title = text.split('\n').first;
    if (block == null) {
      sync.create(
        kind: BlockKind.message,
        title: title.length > 40 ? '${title.substring(0, 40)}…' : title,
        payload: {'text': text},
        parentId: parentId,
        viewedMode: defaultViewedMode(context),
      );
    } else {
      sync.update(block.id, title: title, payload: {...block.payload, 'text': text});
    }
    return true;
  }
}

// ------------------------------------------------------------------ note

class NoteType extends BlockType {
  @override
  BlockKind get kind => BlockKind.note;
  @override
  String get label => '笔记';
  @override
  IconData get icon => Icons.sticky_note_2_outlined;
  @override
  Color color(ColorScheme cs) => cs.tertiary;
  @override
  String get executeLabel => '打开';

  static String mdOf(Block b) => (b.payload['markdown'] ?? '') as String;

  @override
  Widget buildPreview(BuildContext context, Block block) {
    final md = mdOf(block);
    final short = md.length > 300 ? '${md.substring(0, 300)}…' : md;
    return IgnorePointer(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 96),
        child: ClipRect(child: MarkdownBody(data: short, shrinkWrap: true)),
      ),
    );
  }

  @override
  Future<void> execute(BuildContext context, Block block) async {
    AppScope.of(context).sync.setViewed(block.id, true);
    await Navigator.of(context).push(_fade(NoteEditorPage(blockId: block.id)));
  }

  @override
  Future<bool> edit(BuildContext context, Block? block, {String? parentId}) async {
    if (block != null) {
      await execute(context, block);
      return true;
    }
    final r = await Navigator.of(context)
        .push<bool>(_fade(NoteEditorPage(parentId: parentId)));
    return r == true;
  }
}

// ------------------------------------------------------------------ file

// ignore: camel_case_types
class FileType_ extends BlockType {
  @override
  BlockKind get kind => BlockKind.file;
  @override
  String get label => '文件';
  @override
  IconData get icon => Icons.insert_drive_file_outlined;
  @override
  Color color(ColorScheme cs) => cs.secondary;
  @override
  String get executeLabel => '打开';

  static String _fmtSize(int s) {
    if (s < 1024) return '$s B';
    if (s < 1024 * 1024) return '${(s / 1024).toStringAsFixed(1)} KB';
    return '${(s / 1024 / 1024).toStringAsFixed(1)} MB';
  }

  @override
  Widget buildPreview(BuildContext context, Block block) {
    final name = (block.payload['name'] ?? block.title) as String;
    final size = (block.payload['size'] ?? 0) as int;
    return Row(children: [
      Icon(Icons.attach_file, size: 16, color: Theme.of(context).colorScheme.outline),
      const SizedBox(width: 4),
      Expanded(child: Text('$name · ${_fmtSize(size)}', overflow: TextOverflow.ellipsis)),
    ]);
  }

  Future<File> _download(BuildContext context, Block block) async {
    final s = AppScope.of(context);
    final fileId = block.payload['file_id'] as String?;
    if (fileId == null) throw Exception('文件尚未上传');
    final bytes = await s.api.downloadFile(s.settings.server!, s.settings.token!, fileId);
    Directory? dir;
    try {
      dir = await getDownloadsDirectory();
    } catch (_) {}
    dir ??= await getApplicationDocumentsDirectory();
    final out = File('${dir.path}${Platform.pathSeparator}SyncNotes${Platform.pathSeparator}${block.payload['name'] ?? block.id}');
    await out.parent.create(recursive: true);
    await out.writeAsBytes(bytes);
    return out;
  }

  @override
  Future<void> execute(BuildContext context, Block block) async {
    AppScope.of(context).sync.setViewed(block.id, true);
    _toast(context, '正在下载…');
    try {
      final f = await _download(context, block);
      final r = await OpenFilex.open(f.path);
      if (context.mounted && r.type != ResultType.done) _toast(context, '已保存到 ${f.path}');
    } catch (e) {
      if (context.mounted) _toast(context, '打开失败：$e');
    }
  }

  @override
  List<BlockAction> extraActions(BuildContext context, Block block) => [
        BlockAction('下载', Icons.download, () async {
          try {
            final f = await _download(context, block);
            if (context.mounted) _toast(context, '已保存到 ${f.path}');
          } catch (e) {
            if (context.mounted) _toast(context, '下载失败：$e');
          }
        }),
      ];

  @override
  Future<bool> edit(BuildContext context, Block? block, {String? parentId}) async {
    final s = AppScope.of(context);
    if (block != null) {
      // 重命名
      final ctrl = TextEditingController(text: block.title);
      final ok = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('重命名文件'),
          content: TextField(controller: ctrl, autofocus: true),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('取消')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('保存')),
          ],
        ),
      );
      if (ok == true) s.sync.update(block.id, title: ctrl.text.trim());
      return ok == true;
    }
    final res = await FilePicker.pickFiles();
    if (res.isEmpty) return false;
    final pf = res.first;
    final List<int> bytes = await pf.xFile.readAsBytes();
    if (!context.mounted) return false;
    _toast(context, '正在上传 ${pf.name}…');
    try {
      final id = await s.api.uploadFile(s.settings.server!, s.settings.token!, pf.name, bytes);
      if (!context.mounted) return false;
      s.sync.create(
        kind: BlockKind.file,
        title: pf.name,
        payload: {'name': pf.name, 'size': bytes.length, 'file_id': id},
        parentId: parentId,
        viewedMode: defaultViewedMode(context),
      );
      _toast(context, '上传完成');
      return true;
    } catch (e) {
      if (context.mounted) _toast(context, '上传失败（需在线）：$e');
      return false;
    }
  }
}

// ------------------------------------------------------------------ folder

class FolderType extends BlockType {
  @override
  BlockKind get kind => BlockKind.folder;
  @override
  String get label => '文件夹';
  @override
  IconData get icon => Icons.folder_outlined;
  @override
  Color color(ColorScheme cs) => cs.primaryContainer;
  @override
  String get executeLabel => '进入';

  @override
  Widget buildPreview(BuildContext context, Block block) {
    final sync = AppScope.of(context).sync;
    final kids = sync.childrenOf(block.id);
    final unread = kids.where((k) => !k.isViewed && k.kind != BlockKind.folder).length;
    return Text('${kids.length} 项${unread > 0 ? ' · $unread 未读' : ''}',
        style: Theme.of(context).textTheme.bodySmall);
  }

  @override
  Future<void> execute(BuildContext context, Block block) async {
    await Navigator.of(context).push(_fade(FolderPage(folderId: block.id)));
  }

  @override
  Future<bool> edit(BuildContext context, Block? block, {String? parentId}) async {
    final ctrl = TextEditingController(text: block?.title ?? '');
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(block == null ? '新建文件夹' : '重命名文件夹'),
        content: TextField(
            controller: ctrl,
            autofocus: true,
            decoration: const InputDecoration(hintText: '文件夹名称')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('确定')),
        ],
      ),
    );
    if (ok != true || ctrl.text.trim().isEmpty || !context.mounted) return false;
    final sync = AppScope.of(context).sync;
    if (block == null) {
      sync.create(
          kind: BlockKind.folder,
          title: ctrl.text.trim(),
          parentId: parentId,
          viewedMode: ViewedMode.global);
    } else {
      sync.update(block.id, title: ctrl.text.trim());
    }
    return true;
  }
}

// ------------------------------------------------------------------ unknown

class UnknownType extends BlockType {
  @override
  BlockKind get kind => BlockKind.unknown;
  @override
  String get label => '未知类型';
  @override
  IconData get icon => Icons.help_outline;
  @override
  Color color(ColorScheme cs) => cs.outline;
  @override
  String get executeLabel => '查看';
  @override
  Widget buildPreview(BuildContext context, Block block) =>
      const Text('此类型需要更新客户端才能显示');
  @override
  Future<void> execute(BuildContext context, Block block) async {}
  @override
  Future<bool> edit(BuildContext context, Block? block, {String? parentId}) async => false;
}

Route<T> _fade<T>(Widget page) => PageRouteBuilder<T>(
      pageBuilder: (_, _, _) => page,
      transitionDuration: const Duration(milliseconds: 260),
      reverseTransitionDuration: const Duration(milliseconds: 200),
      transitionsBuilder: (_, a, _, child) {
        final curved = CurvedAnimation(parent: a, curve: Curves.easeOutCubic);
        return FadeTransition(
          opacity: curved,
          child: SlideTransition(
            position: Tween(begin: const Offset(0, 0.04), end: Offset.zero).animate(curved),
            child: child,
          ),
        );
      },
    );
