import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../models/block.dart';

/// 可扩展块类型：每种类型定义自己的 显示 / 编辑 / 执行 行为。
/// 新类型：实现 [BlockType] 并在 [BlockTypes.register] 中注册即可。
abstract class BlockType {
  BlockKind get kind;
  String get label;
  IconData get icon;
  Color color(ColorScheme cs);

  /// 列表中的预览内容。
  Widget buildPreview(BuildContext context, Block block);

  /// 主操作（点击）：消息=查看/复制，笔记=打开编辑，文件=下载打开，文件夹=进入。
  Future<void> execute(BuildContext context, Block block);

  /// 编辑/新建。block 为 null 表示新建；返回 true 表示已保存。
  Future<bool> edit(BuildContext context, Block? block, {String? parentId});

  /// 主操作按钮文字
  String get executeLabel;

  /// 额外的上下文菜单动作
  List<BlockAction> extraActions(BuildContext context, Block block) => const [];
}

class BlockAction {
  final String label;
  final IconData icon;
  final Future<void> Function() run;
  const BlockAction(this.label, this.icon, this.run);
}

class BlockTypes {
  static final Map<BlockKind, BlockType> _registry = {};

  static void register(BlockType t) => _registry[t.kind] = t;

  static BlockType of(BlockKind k) => _registry[k] ?? _registry[BlockKind.unknown]!;

  static List<BlockType> get creatable =>
      _registry.values.where((t) => !_hidden.contains(t.kind)).toList();

  /// 旧版 Markdown 笔记仍可显示/编辑，但新建统一使用页面。
  static const _hidden = {BlockKind.unknown, BlockKind.note, BlockKind.text};

  static bool get isInitialized => _registry.isNotEmpty;
}

ViewedMode defaultViewedMode(BuildContext context) =>
    AppScope.of(context).settings.defaultGlobalViewed ? ViewedMode.global : ViewedMode.perDevice;
