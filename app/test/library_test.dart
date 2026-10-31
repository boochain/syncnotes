import 'package:flutter_test/flutter_test.dart';
import 'package:syncnotes/library.dart';
import 'package:syncnotes/session.dart';

Note _n(String id, {String title = '', String body = '', bool pinned = false, bool trashed = false, bool folder = false, String? folderId, List<String> tags = const [], int updated = 1, int? created}) {
  return Note(id: id, title: title, body: body, pinned: pinned, trashed: trashed, folder: folder, folderId: folderId, tags: tags, updatedAt: updated, createdAt: created);
}

void main() {
  test('library keeps folders, pins, tags, trash and search apart', () {
    final notes = [
      _n('a', title: '买菜', body: '- [ ] 牛奶', pinned: true, tags: ['生活'], updated: 2),
      _n('b', title: '草稿', body: 'see [[买菜]]', updated: 5),
      _n('c', title: '旧的', trashed: true, updated: 9),
      _n('f', title: '工作', folder: true),
      _n('d', title: '周报', folderId: 'f', updated: 3),
    ];
    expect(selectNotes(notes, view: 'all').map((n) => n.id), ['a', 'b', 'd']);
    expect(selectNotes(notes, view: 'pinned').map((n) => n.id), ['a']);
    expect(selectNotes(notes, view: 'trash').map((n) => n.id), ['c']);
    expect(selectNotes(notes, view: 'folder', folderId: 'f').map((n) => n.id), ['d']);
    expect(selectNotes(notes, view: 'tag', tag: '生活').map((n) => n.id), ['a']);
    expect(selectNotes(notes, view: 'all', query: '牛奶').single.id, 'a');
    expect(folderNotes(notes).single.id, 'f');
    expect(allTags(notes), ['生活']);
    expect(backlinksOf(notes, notes.first).single.id, 'b');
    expect(taskProgress(notes.first.body).total, 1);
  });

  test('markdown helpers and export keep the words', () {
    expect(dailyTitle(DateTime(2026, 10, 31)), '日记 2026-10-31');
    expect(wordCount('买菜 hello'), 3);
    expect(wrapRange('abcd', 1, 3, '**', '**'), 'a**bc**d');
    expect(prefixLines('a\nb', 2, 2, '- '), 'a\n- b');
    expect(toggleTaskLine('- [ ] 牛奶', 0), '- [x] 牛奶');
    final n = _n('a', title: '买菜', body: '牛奶', tags: ['生活']);
    expect(exportMarkdown(n), contains('# 买菜'));
    expect(exportMarkdown(n), contains('#生活'));
    final again = Note.decode(n.id, n.encode(), n.updatedAt);
    expect(again.tags, ['生活']);
    expect(again.title, '买菜');
  });
}
