import 'package:flutter/material.dart';

import 'library.dart';

class MarkdownBody extends StatelessWidget {
  const MarkdownBody({super.key, required this.text, this.onWiki, this.onToggleTask});
  final String text;
  final void Function(String title)? onWiki;
  final void Function(int line)? onToggleTask;

  @override
  Widget build(BuildContext context) {
    final lines = text.split('\n');
    final children = <Widget>[];
    var i = 0;
    while (i < lines.length) {
      if (lines[i].startsWith('```')) {
        final buf = <String>[];
        i++;
        while (i < lines.length && !lines[i].startsWith('```')) {
          buf.add(lines[i]);
          i++;
        }
        if (i < lines.length) i++;
        children.add(Container(
          width: double.infinity,
          margin: const EdgeInsets.symmetric(vertical: 6),
          padding: const EdgeInsets.all(12),
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: Text(buf.join('\n'), style: const TextStyle(fontFamily: 'monospace')),
        ));
        continue;
      }
      children.add(_line(context, lines[i], i));
      i++;
    }
    if (children.isEmpty) children.add(const Text('空笔记'));
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: children);
  }

  Widget _line(BuildContext context, String line, int index) {
    final style = Theme.of(context).textTheme.bodyLarge;
    if (line.startsWith('### ')) return Padding(padding: const EdgeInsets.only(top: 8), child: Text(line.substring(4), style: Theme.of(context).textTheme.titleMedium));
    if (line.startsWith('## ')) return Padding(padding: const EdgeInsets.only(top: 10), child: Text(line.substring(3), style: Theme.of(context).textTheme.titleLarge));
    if (line.startsWith('# ')) return Padding(padding: const EdgeInsets.only(top: 12), child: Text(line.substring(2), style: Theme.of(context).textTheme.headlineSmall));
    if (line.startsWith('> ')) {
      return Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.only(left: 10),
        decoration: BoxDecoration(border: Border(left: BorderSide(color: Theme.of(context).colorScheme.outline, width: 3))),
        child: Text(_plain(line.substring(2)), style: style),
      );
    }
    if (line.startsWith('- [ ] ') || line.startsWith('- [x] ') || line.startsWith('- [X] ')) {
      final done = !line.startsWith('- [ ] ');
      return CheckboxListTile(
        contentPadding: EdgeInsets.zero,
        dense: true,
        value: done,
        onChanged: onToggleTask == null ? null : (_) => onToggleTask!(index),
        title: Text(line.substring(6), style: TextStyle(decoration: done ? TextDecoration.lineThrough : null)),
      );
    }
    if (line.startsWith('- ') || line.startsWith('* ')) return Text('• ${_plain(line.substring(2))}', style: style);
    if (RegExp(r'^\d+\. ').hasMatch(line)) return Text(_plain(line), style: style);
    if (line.trim() == '---') return const Divider();
    return Padding(padding: const EdgeInsets.symmetric(vertical: 2), child: _rich(context, line, style));
  }

  String _plain(String line) => line.replaceAll('**', '').replaceAll('`', '');

  Widget _rich(BuildContext context, String line, TextStyle? style) {
    final titles = wikiTitles(line);
    if (titles.isEmpty) return Text(_plain(line), style: style);
    final spans = <InlineSpan>[];
    var rest = line;
    for (final title in titles) {
      final token = '[[$title]]';
      final at = rest.indexOf(token);
      if (at < 0) continue;
      if (at > 0) spans.add(TextSpan(text: _plain(rest.substring(0, at))));
      spans.add(WidgetSpan(
        alignment: PlaceholderAlignment.middle,
        child: InkWell(onTap: onWiki == null ? null : () => onWiki!(title), child: Text(title, style: TextStyle(color: Theme.of(context).colorScheme.primary))),
      ));
      rest = rest.substring(at + token.length);
    }
    if (rest.isNotEmpty) spans.add(TextSpan(text: _plain(rest)));
    return Text.rich(TextSpan(style: style, children: spans));
  }
}
