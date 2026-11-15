import 'dart:math';

import 'package:flutter/foundation.dart';

import '../models/block.dart';
import '../sync/sync_client.dart';

/// 页面内容块的类型（存放在 payload.type）。
enum DocType { paragraph, h1, h2, h3, bullet, numbered, todo, toggle, quote, callout, code, divider, image }

DocType docTypeOf(Block b) =>
    DocType.values.firstWhere((t) => t.name == b.payload['type'], orElse: () => DocType.paragraph);

double orderOf(Block b) => (b.payload['order'] as num?)?.toDouble() ?? b.createdAt.toDouble();

String docText(Block b) => (b.payload['text'] ?? '') as String;

/// 有文本输入框的类型
bool isTextual(DocType t) => t != DocType.divider && t != DocType.image;

/// 回车后新块沿用当前类型的列表类
bool continuesOnEnter(DocType t) =>
    t == DocType.bullet || t == DocType.numbered || t == DocType.todo || t == DocType.toggle;

class DocRow {
  final Block block;
  final int depth;

  /// 编号列表的序号（从 1 开始）
  final int number;
  const DocRow(this.block, this.depth, this.number);
  bool get isPage => block.kind == BlockKind.page;
  DocType get type => docTypeOf(block);
}

class _Change {
  final String id;
  final Block? before;
  Block? after;
  _Change(this.id, this.before, this.after);
}

class _Txn {
  final List<_Change> changes;
  final String? key;
  DateTime at;
  _Txn(this.changes, this.key, this.at);
}

class FocusRequest {
  final String id;
  final int offset; // -1 = 末尾
  const FocusRequest(this.id, this.offset);
}

/// 一个页面的编辑控制器：块级增删改、缩进、拖动排序、撤销/重做。
/// 每个内容块都是独立的同步块（kind=text，parent_id=页面或父块），
/// 因此多设备同时编辑同一页面的不同块不会互相覆盖。
class DocController extends ChangeNotifier {
  final SyncClient sync;
  final String pageId;
  final ValueNotifier<FocusRequest?> focusRequest = ValueNotifier(null);
  final ValueNotifier<String?> focusedId = ValueNotifier(null);

  final List<_Txn> _undo = [];
  final List<_Txn> _redo = [];
  List<_Change>? _open;
  static const coalesceWindow = Duration(milliseconds: 1500);

  DocController(this.sync, this.pageId) {
    sync.addListener(_onSync);
  }

  void _onSync() => notifyListeners();

  @override
  void dispose() {
    sync.removeListener(_onSync);
    focusRequest.dispose();
    focusedId.dispose();
    super.dispose();
  }

  Block? get page => sync.byId(pageId);
  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;

  // ------------------------------------------------------------------ tree

  Map<String, List<Block>> _byParent() {
    final m = <String, List<Block>>{};
    for (final b in sync.blocks) {
      if (b.kind != BlockKind.text && b.kind != BlockKind.page) continue;
      if (b.parentId == null) continue;
      (m[b.parentId!] ??= []).add(b);
    }
    for (final l in m.values) {
      l.sort((a, b) {
        final c = orderOf(a).compareTo(orderOf(b));
        return c != 0 ? c : a.id.compareTo(b.id);
      });
    }
    return m;
  }

  List<Block> children(String parent) => _byParent()[parent] ?? const [];

  /// 可见行（展开的折叠块的子块会缩进显示；子页面显示为链接行，不展开）。
  List<DocRow> rows() {
    final m = _byParent();
    final out = <DocRow>[];
    void walk(String p, int depth) {
      var n = 0;
      for (final c in m[p] ?? const <Block>[]) {
        final t = docTypeOf(c);
        n = (c.kind == BlockKind.text && t == DocType.numbered) ? n + 1 : 0;
        out.add(DocRow(c, depth, n));
        if (c.kind == BlockKind.text) {
          final collapsed = t == DocType.toggle && c.payload['collapsed'] == true;
          if (!collapsed) walk(c.id, depth + 1);
        }
      }
    }

    walk(pageId, 0);
    return out;
  }

  // ------------------------------------------------------------------ history

  void _begin() => _open ??= [];

  void _commit({String? key}) {
    final ch = _open;
    _open = null;
    if (ch == null || ch.isEmpty) return;
    final now = DateTime.now();
    if (key != null &&
        _undo.isNotEmpty &&
        _undo.last.key == key &&
        now.difference(_undo.last.at) < coalesceWindow) {
      // 连续输入合并为一步
      final last = _undo.last;
      for (final c in ch) {
        final existing = last.changes.where((x) => x.id == c.id);
        if (existing.isNotEmpty) {
          existing.first.after = c.after;
        } else {
          last.changes.add(c);
        }
      }
      last.at = now;
    } else {
      _undo.add(_Txn(ch, key, now));
      if (_undo.length > 200) _undo.removeAt(0);
    }
    _redo.clear();
  }

  /// 执行一次修改并记录前后状态。
  T _mutate<T>(String id, T Function() action) {
    final before = sync.byId(id);
    final r = action();
    final after = sync.byId(id);
    final list = _open;
    if (list != null) {
      final prev = list.where((c) => c.id == id);
      if (prev.isNotEmpty) {
        prev.first.after = after;
      } else {
        list.add(_Change(id, before, after));
      }
    }
    return r;
  }

  void _applyState(String id, Block? state) {
    final cur = sync.byId(id);
    if (state == null) {
      if (cur != null && !cur.deleted) sync.restore(cur.copyWith(deleted: true));
    } else {
      sync.restore(state);
    }
  }

  void undo() {
    if (_undo.isEmpty) return;
    final t = _undo.removeLast();
    for (final c in t.changes.reversed) {
      _applyState(c.id, c.before);
    }
    _redo.add(t);
    final focus = t.changes.where((c) => c.before != null && !c.before!.deleted).map((c) => c.id);
    if (focus.isNotEmpty) focusRequest.value = FocusRequest(focus.first, -1);
    notifyListeners();
  }

  void redo() {
    if (_redo.isEmpty) return;
    final t = _redo.removeLast();
    for (final c in t.changes) {
      _applyState(c.id, c.after);
    }
    _undo.add(t);
    notifyListeners();
  }

  // ------------------------------------------------------------------ ops

  double _orderAfter(Block? ref, String parent) {
    final sibs = children(parent);
    if (ref == null) {
      return sibs.isEmpty ? 1000 : orderOf(sibs.first) - 1000;
    }
    final i = sibs.indexWhere((b) => b.id == ref.id);
    final a = orderOf(ref);
    if (i < 0 || i == sibs.length - 1) return a + 1000;
    final b = orderOf(sibs[i + 1]);
    return (a + b) / 2;
  }

  double _orderAtEnd(String parent) {
    final sibs = children(parent);
    return sibs.isEmpty ? 1000 : orderOf(sibs.last) + 1000;
  }

  Block _create(String parent, double order, DocType type, String text, {Map<String, dynamic>? extra}) {
    final b = sync.create(
      kind: BlockKind.text,
      title: '',
      payload: {'type': type.name, 'text': text, 'order': order, ...?extra},
      parentId: parent,
      viewedMode: ViewedMode.global,
    );
    _open?.add(_Change(b.id, null, b));
    return b;
  }

  /// 在 ref 之后插入新块（ref 为 null 时插在页面末尾）。返回新块 id 并请求聚焦。
  String insertAfter(Block? ref, {DocType type = DocType.paragraph, String text = '', bool focus = true, Map<String, dynamic>? extra}) {
    _begin();
    final parent = ref?.parentId ?? pageId;
    final order = ref == null ? _orderAtEnd(pageId) : _orderAfter(ref, parent);
    final b = _create(parent, order, type, text, extra: extra);
    _commit();
    if (focus) focusRequest.value = FocusRequest(b.id, 0);
    return b.id;
  }

  /// 在页面开头插入
  String insertFirst({DocType type = DocType.paragraph}) {
    _begin();
    final b = _create(pageId, _orderAfter(null, pageId), type, '');
    _commit();
    focusRequest.value = FocusRequest(b.id, 0);
    return b.id;
  }

  void setText(String id, String text) {
    final b = sync.byId(id);
    if (b == null || docText(b) == text) return;
    _begin();
    _mutate(id, () => sync.update(id, payload: {...b.payload, 'text': text}));
    _commit(key: 'text:$id');
  }

  void setPayload(String id, Map<String, dynamic> patch, {String? coalesceKey}) {
    final b = sync.byId(id);
    if (b == null) return;
    _begin();
    _mutate(id, () => sync.update(id, payload: {...b.payload, ...patch}));
    _commit(key: coalesceKey);
  }

  void setType(String id, DocType type, {String? text}) {
    final b = sync.byId(id);
    if (b == null) return;
    _begin();
    _mutate(id, () => sync.update(id, payload: {
          ...b.payload,
          'type': type.name,
          'text': ?text,
          if (type == DocType.todo && b.payload['checked'] == null) 'checked': false,
        }));
    if (type == DocType.divider) {
      // 分割线后自动接一个段落方便继续输入
      final p = sync.byId(id)!;
      final nb = _create(p.parentId ?? pageId, _orderAfter(p, p.parentId ?? pageId), DocType.paragraph, '');
      _commit();
      focusRequest.value = FocusRequest(nb.id, 0);
      return;
    }
    _commit();
    focusRequest.value = FocusRequest(id, text?.length ?? -1);
  }

  /// 回车：在光标处拆分。返回新块 id。
  String split(String id, String before, String after) {
    final b = sync.byId(id)!;
    final t = docTypeOf(b);
    // 空列表项回车 → 变成普通段落（若在缩进中则先减少缩进）
    if (continuesOnEnter(t) && before.isEmpty && after.isEmpty) {
      final parent = sync.byId(b.parentId ?? '');
      if (parent != null && parent.kind == BlockKind.text) {
        outdent(id);
      } else {
        setType(id, DocType.paragraph, text: '');
      }
      return id;
    }
    _begin();
    _mutate(id, () => sync.update(id, payload: {...b.payload, 'text': before}));
    final cur = sync.byId(id)!;
    final newType = continuesOnEnter(t) ? t : DocType.paragraph;
    // 展开的折叠块：新块作为第一个子块
    final expandedToggle = t == DocType.toggle && cur.payload['collapsed'] != true && children(id).isNotEmpty;
    final Block nb;
    if (expandedToggle) {
      nb = _create(id, _orderAfter(null, id), DocType.paragraph, after);
    } else {
      final parent = cur.parentId ?? pageId;
      nb = _create(parent, _orderAfter(cur, parent), newType, after,
          extra: newType == DocType.todo ? {'checked': false} : null);
    }
    _commit();
    focusRequest.value = FocusRequest(nb.id, 0);
    return nb.id;
  }

  /// 删除块（含子块），记录以便撤销。
  void remove(String id, {bool focusPrevious = true}) {
    final rs = rows();
    final idx = rs.indexWhere((r) => r.block.id == id);
    final prev = idx > 0 ? rs[idx - 1].block : null;
    _begin();
    final ids = [id, ...sync.descendantIds(id)];
    for (final x in ids.reversed) {
      _mutate(x, () {
        final cur = sync.byId(x);
        if (cur != null && !cur.deleted) sync.restore(cur.copyWith(deleted: true));
      });
    }
    _commit();
    if (focusPrevious && prev != null) focusRequest.value = FocusRequest(prev.id, -1);
  }

  /// 退格合并到上一个文本块。返回 false 表示没有可合并的块。
  bool mergeWithPrevious(String id, String text) {
    final rs = rows();
    final idx = rs.indexWhere((r) => r.block.id == id);
    if (idx <= 0) return false;
    {
      final r = rs[idx - 1];
      if (r.isPage) return false;
      if (!isTextual(r.type)) {
        // 上一个是分割线/图片：直接删掉它
        remove(r.block.id, focusPrevious: false);
        focusRequest.value = FocusRequest(id, 0);
        return true;
      }
      final prevText = docText(r.block);
      _begin();
      _mutate(r.block.id, () => sync.update(r.block.id, payload: {...r.block.payload, 'text': prevText + text}));
      // 子块上移到前一个块之后
      for (final c in children(id)) {
        _mutate(c.id, () => sync.update(c.id, parentId: r.block.parentId ?? pageId,
            payload: {...c.payload, 'order': _orderAfter(r.block, r.block.parentId ?? pageId)}));
      }
      _mutate(id, () {
        final cur = sync.byId(id)!;
        sync.restore(cur.copyWith(deleted: true));
      });
      _commit();
      focusRequest.value = FocusRequest(r.block.id, prevText.length);
      return true;
    }
  }

  /// Tab：成为上一个同级块的子块。
  bool indent(String id) {
    final b = sync.byId(id);
    if (b == null) return false;
    final parent = b.parentId ?? pageId;
    final sibs = children(parent);
    final i = sibs.indexWhere((x) => x.id == id);
    if (i <= 0) return false;
    final newParent = sibs[i - 1];
    if (newParent.kind != BlockKind.text || !isTextual(docTypeOf(newParent))) return false;
    _begin();
    if (docTypeOf(newParent) == DocType.toggle && newParent.payload['collapsed'] == true) {
      _mutate(newParent.id, () => sync.update(newParent.id, payload: {...newParent.payload, 'collapsed': false}));
    }
    _mutate(id, () => sync.update(id, parentId: newParent.id, payload: {...b.payload, 'order': _orderAtEnd(newParent.id)}));
    _commit();
    focusRequest.value = FocusRequest(id, -2);
    return true;
  }

  /// Shift+Tab：移到父块之后。
  bool outdent(String id) {
    final b = sync.byId(id);
    if (b == null || b.parentId == null || b.parentId == pageId) return false;
    final parent = sync.byId(b.parentId!);
    if (parent == null || parent.kind != BlockKind.text) return false;
    final gp = parent.parentId ?? pageId;
    _begin();
    _mutate(id, () => sync.update(id, parentId: gp, payload: {...b.payload, 'order': _orderAfter(parent, gp)}));
    _commit();
    focusRequest.value = FocusRequest(id, -2);
    return true;
  }

  /// 拖动排序（可见行索引，ReorderableList 语义）。
  void moveRow(int oldIndex, int newIndex) {
    final rs = rows();
    if (oldIndex < 0 || oldIndex >= rs.length) return;
    if (newIndex > oldIndex) newIndex -= 1;
    if (newIndex == oldIndex) return;
    final moving = rs[oldIndex].block;
    final banned = sync.descendantIds(moving.id);
    final rest = [for (final r in rs) if (r.block.id != moving.id && !banned.contains(r.block.id)) r];
    newIndex = newIndex.clamp(0, rest.length);
    String parent;
    double order;
    if (newIndex >= rest.length) {
      parent = pageId;
      order = _orderAtEnd(pageId);
    } else {
      final target = rest[newIndex].block;
      parent = target.parentId ?? pageId;
      final sibs = children(parent).where((x) => x.id != moving.id).toList();
      final ti = sibs.indexWhere((x) => x.id == target.id);
      final hi = orderOf(target);
      final lo = ti > 0 ? orderOf(sibs[ti - 1]) : hi - 2000;
      order = (lo + hi) / 2;
    }
    _begin();
    _mutate(moving.id, () => sync.update(moving.id, parentId: parent, payload: {...moving.payload, 'order': order}));
    _commit();
  }

  /// 在当前页面下创建子页面（以链接行显示），返回 id。
  String createSubpage(Block? after, {String title = ''}) {
    _begin();
    // 子页面总是挂在当前页面下（侧边栏树结构依赖于此）
    final order = (after == null || after.parentId != pageId) ? _orderAtEnd(pageId) : _orderAfter(after, pageId);
    final p = sync.create(
      kind: BlockKind.page,
      title: title,
      payload: {'icon': '📄', 'order': order},
      parentId: pageId,
      viewedMode: ViewedMode.global,
    );
    _open?.add(_Change(p.id, null, p));
    _commit();
    return p.id;
  }

  // ------------------------------------------------------------------ page-level

  List<Block> breadcrumbs() {
    final out = <Block>[];
    var cur = page;
    final seen = <String>{};
    while (cur != null && cur.parentId != null && seen.add(cur.id)) {
      final p = sync.byId(cur.parentId!);
      if (p == null || p.deleted) break;
      out.insert(0, p);
      cur = p;
    }
    return out;
  }

  static double nextRootOrder(SyncClient sync, String? parent) {
    final sibs = sync.blocks.where((b) => b.kind == BlockKind.page && b.parentId == parent);
    return sibs.isEmpty ? 1000 : sibs.map(orderOf).reduce(max) + 1000;
  }
}
