import 'package:flutter_test/flutter_test.dart';
import 'package:syncnotes/models/block.dart';
import 'package:syncnotes/pages/doc.dart';
import 'package:syncnotes/pages/inline_md.dart';
import 'package:syncnotes/pages/commands.dart';
import 'package:syncnotes/sync/local_store.dart';
import 'package:syncnotes/sync/sync_client.dart';
import 'package:syncnotes/ui/quick_switcher.dart';
import 'package:syncnotes/ui/sidebar.dart';

void main() {
  late SyncClient sync;
  late String pageId;
  late DocController doc;

  setUp(() {
    sync = SyncClient(store: MemoryStore(), deviceId: 'dev-t');
    pageId = createPage(sync, null, title: '项目');
    doc = DocController(sync, pageId);
  });
  tearDown(() => doc.dispose());

  List<String> texts() => doc.rows().map((r) => docText(r.block)).toList();

  test('content blocks are separate text blocks under the page (block-level sync)', () {
    final a = doc.insertAfter(null, text: 'A');
    final b = doc.insertAfter(sync.byId(a), text: 'B');
    expect(texts(), ['A', 'B']);
    expect(sync.byId(a)!.kind, BlockKind.text);
    expect(sync.byId(b)!.parentId, pageId);
    // 每个块单独排入发件箱
    expect(sync.pendingCount, greaterThanOrEqualTo(3));
  });

  test('split, merge, undo and redo', () {
    final a = doc.insertAfter(null, text: '你好世界');
    final n = doc.split(a, '你好', '世界');
    expect(texts(), ['你好', '世界']);
    expect(doc.mergeWithPrevious(n, '世界'), isTrue);
    expect(texts(), ['你好世界']);
    doc.undo();
    expect(texts(), ['你好', '世界']);
    doc.undo();
    expect(texts(), ['你好世界']);
    doc.redo();
    expect(texts(), ['你好', '世界']);
  });

  test('Enter on empty list item turns it into a paragraph; list type continues', () {
    final a = doc.insertAfter(null, type: DocType.bullet, text: '一');
    final b = doc.split(a, '一', '');
    expect(docTypeOf(sync.byId(b)!), DocType.bullet);
    doc.split(b, '', '');
    expect(docTypeOf(sync.byId(b)!), DocType.paragraph);
  });

  test('indent/outdent nest blocks and numbered lists count per level', () {
    final a = doc.insertAfter(null, type: DocType.numbered, text: '1');
    final b = doc.insertAfter(sync.byId(a), type: DocType.numbered, text: '2');
    final c = doc.insertAfter(sync.byId(b), type: DocType.numbered, text: '3');
    expect(doc.rows().map((r) => r.number), [1, 2, 3]);
    expect(doc.indent(c), isTrue);
    expect(sync.byId(c)!.parentId, b);
    final rs = doc.rows();
    expect(rs.map((r) => r.depth), [0, 0, 1]);
    expect(rs.last.number, 1);
    expect(doc.outdent(c), isTrue);
    expect(sync.byId(c)!.parentId, pageId);
  });

  test('collapsed toggle hides children', () {
    final t = doc.insertAfter(null, type: DocType.toggle, text: '折叠');
    final k = doc.insertAfter(sync.byId(t), text: '子');
    doc.indent(k);
    expect(doc.rows().length, 2);
    doc.setPayload(t, {'collapsed': true});
    expect(doc.rows().length, 1);
  });

  test('moveRow reorders and can be undone', () {
    final a = doc.insertAfter(null, text: 'A');
    final b = doc.insertAfter(sync.byId(a), text: 'B');
    doc.insertAfter(sync.byId(b), text: 'C');
    doc.moveRow(2, 0);
    expect(texts(), ['C', 'A', 'B']);
    doc.moveRow(0, 3);
    expect(texts(), ['A', 'B', 'C']);
    doc.undo();
    expect(texts(), ['C', 'A', 'B']);
  });

  test('remove deletes descendants and undo restores them', () {
    final t = doc.insertAfter(null, type: DocType.toggle, text: 'T');
    final k = doc.insertAfter(sync.byId(t), text: 'K');
    doc.indent(k);
    doc.remove(t);
    expect(doc.rows(), isEmpty);
    expect(sync.byId(k)!.deleted, isTrue);
    doc.undo();
    expect(texts(), ['T', 'K']);
  });

  test('subpages, breadcrumbs, sidebar tree', () {
    final sub = doc.createSubpage(null, title: '子页面');
    final subDoc = DocController(sync, sub);
    final subsub = subDoc.createSubpage(null, title: '孙页面');
    final d3 = DocController(sync, subsub);
    expect(d3.breadcrumbs().map((b) => b.title), ['项目', '子页面']);
    expect(rootPages(sync).map((b) => b.id), [pageId]);
    expect(childPages(sync, pageId).map((b) => b.id), [sub]);
    expect(doc.rows().single.isPage, isTrue);
    subDoc.dispose();
    d3.dispose();
  });

  test('typing coalesces into one undo step', () {
    final a = doc.insertAfter(null);
    doc.setText(a, '一');
    doc.setText(a, '一二');
    doc.setText(a, '一二三');
    doc.undo();
    expect(texts(), ['']);
  });

  test('markdown shortcuts', () {
    expect(detectShortcut('# 标题'), ('h1', '标题'));
    expect(detectShortcut('## x'), ('h2', 'x'));
    expect(detectShortcut('- '), ('bullet', ''));
    expect(detectShortcut('1. a'), ('numbered', 'a'));
    expect(detectShortcut('[] a')?.$1, 'todo');
    expect(detectShortcut('> a')?.$1, 'quote');
    expect(detectShortcut('```')?.$1, 'code');
    expect(detectShortcut('---')?.$1, 'divider');
    expect(detectShortcut('普通文本'), isNull);
  });

  test('slash command filter matches Chinese and English', () {
    expect(filterCommands('').length, slashCommands.length);
    expect(filterCommands('h1').first.type, DocType.h1);
    expect(filterCommands('代码').first.type, DocType.code);
    expect(filterCommands('todo').first.type, DocType.todo);
    expect(filterCommands('zzzz'), isEmpty);
  });

  test('quick switcher searches titles and content', () {
    final a = doc.insertAfter(null, text: '季度预算讨论');
    expect(a, isNotEmpty);
    expect(searchAll(sync, '项目').first.target.id, pageId);
    final hit = searchAll(sync, '预算');
    expect(hit.single.target.id, pageId);
    expect(hit.single.subtitle, contains('预算'));
    expect(searchAll(sync, '不存在的'), isEmpty);
  });

  test('text blocks never appear in the inbox', () {
    doc.insertAfter(null, text: 'x');
    expect(sync.childrenOf(null).where((b) => b.kind == BlockKind.text), isEmpty);
    expect(sync.unreadCount, 0);
  });
}
