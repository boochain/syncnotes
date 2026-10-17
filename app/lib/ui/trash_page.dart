import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../blocks/block_type.dart';
import '../models/block.dart';
import '../sync/sync_client.dart';
import 'block_card.dart' show EmptyState, relTime;
import 'ds.dart';

/// 设备名：本设备显示"本设备"，其他设备显示 id 前 8 位。
String deviceLabel(SyncClient sync, String? id) {
  if (id == null || id.isEmpty) return '未知设备';
  if (id == sync.deviceId) return '本设备';
  return id.length > 8 ? '设备 ${id.substring(0, 8)}' : '设备 $id';
}

String retentionNote(int days) => days <= 0 ? '回收站中的内容会一直保留，直到你彻底删除。' : '回收站中的内容会在删除 $days 天后自动彻底删除。';

/// 回收站：列出已删除内容，可恢复 / 彻底删除 / 清空；支持多选和搜索。
class TrashPage extends StatefulWidget {
  const TrashPage({super.key});
  @override
  State<TrashPage> createState() => _TrashPageState();
}

class _TrashPageState extends State<TrashPage> {
  final _selected = <String>{};
  String _query = '';
  bool _healthLoaded = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_healthLoaded) return;
    _healthLoaded = true;
    final s = AppScope.of(context);
    final server = s.settings.server;
    if (server == null || server.isEmpty) return;
    s.api.health(server).then((h) {
      final d = h?['trash_retention_days'];
      if (d is int && mounted) setState(() => s.sync.trashRetentionDays = d);
    });
  }

  String _title(Block b) {
    final t = BlockTypes.of(b.kind);
    if (b.title.trim().isNotEmpty) return shortTitle(b.title, 60);
    final p = t.previewText(context, b).trim();
    return p.isEmpty ? '无标题${t.label}' : shortTitle(p, 60);
  }

  void _restore(List<String> ids) {
    final s = AppScope.of(context);
    final toRoot = s.sync.restoreAll(ids);
    setState(() => _selected.removeAll(ids));
    final n = ids.length;
    showToast(
      context,
      toRoot.isEmpty ? (n == 1 ? '已恢复' : '已恢复 $n 项') : '已恢复 $n 项，其中 ${toRoot.length} 项的原位置已不存在，已放到收件箱根目录',
    );
  }

  Future<void> _purge(List<String> ids) async {
    final s = AppScope.of(context);
    final ok = await confirmDanger(
      context,
      title: '彻底删除',
      message: ids.length == 1 ? '彻底删除后无法恢复（文件夹内的内容和文件也会一并删除）。' : '确定彻底删除选中的 ${ids.length} 项？此操作无法恢复。',
      confirm: '彻底删除',
    );
    if (!ok || !mounted) return;
    s.sync.purge(ids);
    setState(() => _selected.removeAll(ids));
    showToast(context, '已彻底删除');
  }

  Future<void> _empty() async {
    final s = AppScope.of(context);
    final n = s.sync.trash.length;
    final ok = await confirmDanger(context, title: '清空回收站', message: '将彻底删除回收站中的 $n 项内容，此操作无法恢复。', confirm: '清空');
    if (!ok || !mounted) return;
    s.sync.emptyTrash();
    setState(_selected.clear);
    showToast(context, '回收站已清空');
  }

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final c = AppColors.of(context);
    final tt = Theme.of(context).textTheme;
    return ListenableBuilder(
      listenable: s.sync,
      builder: (context, _) {
        final all = s.sync.trash;
        _selected.removeWhere((id) => !all.any((b) => b.id == id));
        final q = _query.trim().toLowerCase();
        final items = q.isEmpty ? all : all.where((b) => _title(b).toLowerCase().contains(q)).toList();
        final selecting = _selected.isNotEmpty;
        return Scaffold(
          appBar: AppBar(
            title: Text(selecting ? '已选择 ${_selected.length} 项' : '回收站'),
            actions: [
              if (selecting) ...[
                TextButton(
                  key: const Key('trashBatchRestore'),
                  onPressed: () => _restore(_selected.toList()),
                  child: const Text('恢复'),
                ),
                TextButton(
                  key: const Key('trashBatchPurge'),
                  onPressed: () => _purge(_selected.toList()),
                  child: Text('彻底删除', style: TextStyle(color: c.danger)),
                ),
                IconButton(
                  tooltip: '取消选择',
                  icon: const Icon(CupertinoIcons.xmark),
                  onPressed: () => setState(_selected.clear),
                ),
              ] else if (all.isNotEmpty)
                TextButton(
                  key: const Key('trashEmpty'),
                  onPressed: _empty,
                  child: Text('清空回收站', style: TextStyle(color: c.danger)),
                ),
              const SizedBox(width: Gap.m),
            ],
          ),
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(Gap.xl, Gap.m, Gap.xl, Gap.m),
                child: Row(
                  children: [
                    Icon(CupertinoIcons.info_circle, size: Sizes.iconSm, color: c.text3),
                    const SizedBox(width: Gap.m),
                    Expanded(
                      child: Text(
                        retentionNote(s.sync.trashRetentionDays),
                        key: const Key('trashRetention'),
                        style: tt.bodySmall?.copyWith(color: c.text2),
                      ),
                    ),
                  ],
                ),
              ),
              if (all.length > 5)
                Padding(
                  padding: const EdgeInsets.fromLTRB(Gap.xl, 0, Gap.xl, Gap.m),
                  child: SizedBox(
                    height: Sizes.input,
                    child: TextField(
                      key: const Key('trashSearch'),
                      onChanged: (v) => setState(() => _query = v),
                      decoration: const InputDecoration(
                        hintText: '搜索回收站',
                        prefixIcon: Icon(CupertinoIcons.search, size: Sizes.iconSm),
                      ),
                    ),
                  ),
                ),
              Divider(height: 1, color: c.separator),
              Expanded(
                child: items.isEmpty
                    ? Center(
                        child: EmptyState(
                          key: const Key('trashEmptyState'),
                          icon: CupertinoIcons.trash,
                          title: all.isEmpty ? '回收站是空的' : '没有匹配的内容',
                          subtitle: all.isEmpty ? '删除的内容会先放在这里，可以随时恢复' : null,
                        ),
                      )
                    : ListView.separated(
                        itemCount: items.length,
                        separatorBuilder: (_, _) =>
                            Divider(height: 1, indent: Gap.xl + Sizes.tile + Gap.l, color: c.separator),
                        itemBuilder: (context, i) => _TrashRow(
                          block: items[i],
                          title: _title(items[i]),
                          selected: _selected.contains(items[i].id),
                          selecting: selecting,
                          onToggle: () => setState(() {
                            final id = items[i].id;
                            _selected.contains(id) ? _selected.remove(id) : _selected.add(id);
                          }),
                          onRestore: () => _restore([items[i].id]),
                          onPurge: () => _purge([items[i].id]),
                        ),
                      ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _TrashRow extends StatelessWidget {
  final Block block;
  final String title;
  final bool selected;
  final bool selecting;
  final VoidCallback onToggle;
  final VoidCallback onRestore;
  final VoidCallback onPurge;
  const _TrashRow({
    required this.block,
    required this.title,
    required this.selected,
    required this.selecting,
    required this.onToggle,
    required this.onRestore,
    required this.onPurge,
  });

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final c = AppColors.of(context);
    final tt = Theme.of(context).textTheme;
    final type = BlockTypes.of(block.kind);
    final kids = block.kind == BlockKind.folder || block.kind == BlockKind.page ? s.sync.trashChildCount(block.id) : 0;
    final meta = [
      type.label,
      if (kids > 0) '含 $kids 项',
      '${relTime(block.deletedAt ?? 0)}删除',
      deviceLabel(s.sync, block.deletedBy),
    ].join(' · ');
    return Material(
      color: selected ? c.selected : Colors.transparent,
      child: InkWell(
        key: Key('trashRow-${block.id}'),
        onTap: selecting ? onToggle : null,
        onLongPress: onToggle,
        child: SizedBox(
          height: Sizes.listRow,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: Gap.xl),
            child: Row(
              children: [
                GestureDetector(
                  onTap: onToggle,
                  child: Container(
                    key: Key('trashSelect-${block.id}'),
                    width: Sizes.tile,
                    height: Sizes.tile,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: selected ? c.accent : c.fill,
                      borderRadius: BorderRadius.circular(AppRadius.s),
                    ),
                    child: Icon(
                      selected ? CupertinoIcons.checkmark : type.icon,
                      size: Sizes.iconSm,
                      color: selected ? Colors.white : c.text2,
                    ),
                  ),
                ),
                const SizedBox(width: Gap.l),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: tt.bodyMedium?.copyWith(fontWeight: FontWeight.w500),
                      ),
                      Text(
                        meta,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: tt.bodySmall?.copyWith(color: c.text2),
                      ),
                    ],
                  ),
                ),
                if (!selecting) ...[
                  const SizedBox(width: Gap.m),
                  SizedBox(
                    height: Sizes.compact,
                    child: TextButton(
                      key: Key('trashRestore-${block.id}'),
                      onPressed: onRestore,
                      child: const Text('恢复'),
                    ),
                  ),
                  SizedBox(
                    width: Sizes.compact,
                    height: Sizes.compact,
                    child: IconButton(
                      key: Key('trashPurge-${block.id}'),
                      tooltip: '彻底删除',
                      padding: EdgeInsets.zero,
                      iconSize: Sizes.iconSm,
                      icon: Icon(CupertinoIcons.delete, color: c.danger),
                      onPressed: onPurge,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
