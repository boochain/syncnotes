import 'session.dart';

const noteTemplates = <String, String>{
  '会议': '## 议题\n\n\n## 结论\n\n- [ ] \n',
  '待办': '## 今天\n\n- [ ] \n- [ ] \n\n## 以后\n\n- [ ] \n',
  '日记': '## 发生了什么\n\n\n## 接下来\n\n- [ ] \n',
};

String dailyTitle(DateTime d) {
  final m = d.month.toString().padLeft(2, '0');
  final day = d.day.toString().padLeft(2, '0');
  return '日记 ${d.year}-$m-$day';
}

final _wiki = RegExp(r'\[\[([^\]\n]+)\]\]');
final _taskOpen = RegExp(r'^- \[ \] ');
final _taskDone = RegExp(r'^- \[[xX]\] ');

List<String> wikiTitles(String body) =>
    [for (final m in _wiki.allMatches(body)) if (m.group(1)!.trim().isNotEmpty) m.group(1)!.trim()];

({int done, int total}) taskProgress(String body) {
  var open = 0;
  var done = 0;
  for (final line in body.split('\n')) {
    if (_taskOpen.hasMatch(line)) open++;
    if (_taskDone.hasMatch(line)) done++;
  }
  return (done: done, total: open + done);
}

int wordCount(String text) {
  final t = text.trim();
  if (t.isEmpty) return 0;
  final cjk = RegExp(r'[\u3400-\u9fff]').allMatches(t).length;
  final words = t.split(RegExp(r'\s+')).where((w) => RegExp(r'[A-Za-z0-9]').hasMatch(w)).length;
  return cjk + words;
}

String wrapRange(String text, int start, int end, String left, String right) {
  final a = start.clamp(0, text.length);
  final b = end.clamp(0, text.length);
  final from = a <= b ? a : b;
  final to = a <= b ? b : a;
  return text.replaceRange(from, to, '$left${text.substring(from, to)}$right');
}

String prefixLines(String text, int start, int end, String prefix) {
  final a = start.clamp(0, text.length);
  final b = end.clamp(0, text.length);
  final from = a <= b ? a : b;
  final to = a <= b ? b : a;
  final lineStart = text.lastIndexOf('\n', from - 1) + 1;
  var lineEnd = text.indexOf('\n', to);
  if (lineEnd < 0) lineEnd = text.length;
  final block = text.substring(lineStart, lineEnd);
  final next = block.split('\n').map((line) {
    if (line.startsWith(prefix)) return line.substring(prefix.length);
    return '$prefix$line';
  }).join('\n');
  return text.replaceRange(lineStart, lineEnd, next);
}

String toggleTaskLine(String text, int lineIndex) {
  final lines = text.split('\n');
  if (lineIndex < 0 || lineIndex >= lines.length) return text;
  final line = lines[lineIndex];
  if (line.startsWith('- [ ] ')) {
    lines[lineIndex] = '- [x] ${line.substring(6)}';
  } else if (line.startsWith('- [x] ') || line.startsWith('- [X] ')) {
    lines[lineIndex] = '- [ ] ${line.substring(6)}';
  } else {
    lines[lineIndex] = '- [ ] $line';
  }
  return lines.join('\n');
}

List<Note> selectNotes(
  List<Note> all, {
  required String view,
  String? folderId,
  String? tag,
  String query = '',
  String sort = 'updated',
}) {
  final q = query.trim().toLowerCase();
  Iterable<Note> list = all.where((n) => !n.folder);
  if (view == 'trash') {
    list = list.where((n) => n.trashed);
  } else {
    list = list.where((n) => !n.trashed);
    if (view == 'pinned') list = list.where((n) => n.pinned);
    if (view == 'folder') list = list.where((n) => n.folderId == folderId);
    if (view == 'tag') list = list.where((n) => n.tags.contains(tag));
  }
  if (q.isNotEmpty) {
    list = list.where((n) {
      final blob = '${n.title}\n${n.body}\n${n.tags.join(' ')}'.toLowerCase();
      return blob.contains(q);
    });
  }
  final out = list.toList();
  out.sort((a, b) {
    if (view != 'trash' && a.pinned != b.pinned) return a.pinned ? -1 : 1;
    switch (sort) {
      case 'title':
        return a.heading.toLowerCase().compareTo(b.heading.toLowerCase());
      case 'created':
        return b.createdAt.compareTo(a.createdAt);
      default:
        return b.updatedAt.compareTo(a.updatedAt);
    }
  });
  return out;
}

List<Note> folderNotes(List<Note> all) => all.where((n) => n.folder && !n.trashed).toList()
  ..sort((a, b) => a.heading.toLowerCase().compareTo(b.heading.toLowerCase()));

List<String> allTags(List<Note> all) {
  final tags = <String>{};
  for (final n in all) {
    if (n.trashed || n.folder) continue;
    tags.addAll(n.tags);
  }
  final out = tags.toList()..sort();
  return out;
}

List<Note> backlinksOf(List<Note> all, Note note) {
  final title = note.title.trim();
  if (title.isEmpty) return const [];
  return [
    for (final other in all)
      if (other.id != note.id && !other.folder && !other.trashed && wikiTitles(other.body).contains(title)) other,
  ];
}

Note? noteByTitle(List<Note> all, String title) {
  final t = title.trim();
  for (final n in all) {
    if (!n.folder && !n.trashed && n.title.trim() == t) return n;
  }
  return null;
}

String exportMarkdown(Note n) {
  final tags = n.tags.isEmpty ? '' : '\n\n标签：${n.tags.map((t) => '#$t').join(' ')}';
  final files = n.files.isEmpty ? '' : '\n\n附件：${n.files.map((f) => f.name).join('、')}';
  return '# ${n.heading}\n\n${n.body}$tags$files\n';
}
