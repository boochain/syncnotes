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
      case 'order':
        final byOrder = a.order.compareTo(b.order);
        if (byOrder != 0) return byOrder;
        return b.updatedAt.compareTo(a.updatedAt);
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

class SlashCommand {
  const SlashCommand(this.name, this.hint, this.insert);
  final String name;
  final String hint;
  final String insert;
}

const slashCommands = <SlashCommand>[
  SlashCommand('待办', '一条可以勾的事', '- [ ] '),
  SlashCommand('列表', '圆点列表', '- '),
  SlashCommand('编号', '按顺序写', '1. '),
  SlashCommand('标题', '一个小节', '## '),
  SlashCommand('引用', '摘一句', '> '),
  SlashCommand('代码', '一段代码', '```\n\n```'),
  SlashCommand('分隔', '一条横线', '---'),
  SlashCommand('日期', '插入今天', '__DATE__'),
  SlashCommand('删除线', '划掉这段', '~~'),
];

List<SlashCommand> matchSlash(String line) {
  if (!line.startsWith('/')) return const [];
  final q = line.substring(1).trim();
  return [for (final c in slashCommands) if (q.isEmpty || c.name.contains(q)) c];
}

String replaceCurrentLine(String text, int cursor, String insert) {
  final at = cursor.clamp(0, text.length);
  final start = text.lastIndexOf('\n', at <= 0 ? 0 : at - 1) + 1;
  var end = text.indexOf('\n', at);
  if (end < 0) end = text.length;
  return text.replaceRange(start, end, insert);
}

class OpenTask {
  const OpenTask(this.noteId, this.title, this.line, this.text);
  final String noteId;
  final String title;
  final int line;
  final String text;
}

List<OpenTask> openTasks(List<Note> notes) {
  final out = <OpenTask>[];
  for (final n in notes) {
    if (n.folder || n.trashed) continue;
    final lines = n.body.split('\n');
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].startsWith('- [ ] ')) out.add(OpenTask(n.id, n.heading, i, lines[i].substring(6)));
    }
  }
  return out;
}

class Heading {
  const Heading(this.line, this.text, this.level);
  final int line;
  final String text;
  final int level;
}

List<Heading> headingsOf(String body) {
  final out = <Heading>[];
  final lines = body.split('\n');
  for (var i = 0; i < lines.length; i++) {
    final m = RegExp(r'^(#{1,3}) (.+)$').firstMatch(lines[i]);
    if (m != null) out.add(Heading(i, m.group(2)!.trim(), m.group(1)!.length));
  }
  return out;
}

int folderCount(List<Note> notes, String id) => notes.where((n) => !n.folder && !n.trashed && n.folderId == id).length;

String relativeTime(int millis, DateTime now) {
  final then = DateTime.fromMillisecondsSinceEpoch(millis);
  final d = now.difference(then);
  if (d.isNegative || d.inSeconds < 45) return '刚刚';
  if (d.inMinutes < 60) return '${d.inMinutes} 分钟前';
  if (d.inHours < 24) return '${d.inHours} 小时前';
  if (d.inDays < 7) return '${d.inDays} 天前';
  return '${then.month}月${then.day}日';
}

int nextMatch(String text, String query, int from) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return -1;
  final hay = text.toLowerCase();
  final start = from.clamp(0, hay.length);
  final at = hay.indexOf(q, start);
  if (at >= 0) return at;
  return hay.indexOf(q);
}

const folderIcons = ['', '📁', '📝', '✅', '💡', '🏠', '💼', '📚', '🔒', '⭐'];

const noteColors = <String, String>{'': '无', 'red': '红', 'amber': '黄', 'green': '绿', 'blue': '蓝', 'purple': '紫'};

String markdownTable() => '| 列1 | 列2 | 列3 |\n| --- | --- | --- |\n|  |  |  |\n|  |  |  |\n';

({String text, int count}) replaceMatches(String text, String find, String replace, {required bool all, int from = 0}) {
  if (find.isEmpty) return (text: text, count: 0);
  if (!all) {
    final at = text.indexOf(find, from.clamp(0, text.length));
    final start = at < 0 ? text.indexOf(find) : at;
    if (start < 0) return (text: text, count: 0);
    return (text: text.replaceRange(start, start + find.length, replace), count: 1);
  }
  final count = find.allMatches(text).length;
  return (text: text.replaceAll(find, replace), count: count);
}

String readableText(String html) {
  final noScript = html.replaceAll(RegExp(r'<script[\s\S]*?</script>', caseSensitive: false), ' ');
  final noStyle = noScript.replaceAll(RegExp(r'<style[\s\S]*?</style>', caseSensitive: false), ' ');
  final titled = RegExp(r'<title>([\s\S]*?)</title>', caseSensitive: false).firstMatch(noStyle);
  final text = noStyle.replaceAll(RegExp(r'<[^>]+>'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
  final title = titled == null ? '' : titled.group(1)!.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (title.isEmpty) return text;
  return '$title\n\n$text';
}

String clipMarkdown({required String url, String title = '', String text = ''}) {
  final head = title.trim().isEmpty ? url : title.trim();
  final body = text.trim();
  return '# $head\n\n来源：$url\n\n$body\n';
}

const bookmarklet = "javascript:(function(){var t=document.title||'';var s=window.getSelection?String(window.getSelection()):'';prompt('复制到 SyncNotes','# '+t+'\\n\\n来源：'+location.href+'\\n\\n'+s);})();";

class GraphEdge {
  const GraphEdge(this.fromId, this.toId);
  final String fromId;
  final String toId;
}

List<GraphEdge> wikiEdges(List<Note> notes) {
  final out = <GraphEdge>[];
  for (final n in notes) {
    if (n.folder || n.trashed || n.title.trim().isEmpty) continue;
    for (final other in backlinksOf(notes, n)) {
      out.add(GraphEdge(other.id, n.id));
    }
  }
  return out;
}

List<Note> smartMatches(List<Note> notes, String query) {
  final q = query.trim();
  if (q.startsWith('tag:')) return selectNotes(notes, view: 'tag', tag: q.substring(4).trim());
  if (q.startsWith('color:')) {
    final color = q.substring(6).trim();
    return notes.where((n) => !n.folder && !n.trashed && n.color == color).toList();
  }
  if (q == 'todo') {
    return notes.where((n) {
      if (n.folder || n.trashed) return false;
      final p = taskProgress(n.body);
      return p.total > 0 && p.done < p.total;
    }).toList();
  }
  return selectNotes(notes, view: 'all', query: q);
}

List<Note> dueNotes(List<Note> notes, int now) => notes.where((n) => !n.trashed && !n.folder && n.remindAt != null && n.remindAt! <= now).toList();

void applyManualOrder(List<Note> visible, int oldIndex, int newIndex) {
  if (oldIndex < 0 || oldIndex >= visible.length) return;
  final target = newIndex.clamp(0, visible.length - 1);
  final item = visible.removeAt(oldIndex);
  visible.insert(target, item);
  for (var i = 0; i < visible.length; i++) {
    visible[i].order = i;
  }
}

bool folderContains(List<Note> notes, String folderId, String noteId) {
  var id = noteId;
  final seen = <String>{};
  while (seen.add(id)) {
    if (id == folderId) return true;
    Note? n;
    for (final e in notes) {
      if (e.id == id) n = e;
    }
    final parent = n?.folderId;
    if (parent == null) return false;
    id = parent;
  }
  return true;
}

