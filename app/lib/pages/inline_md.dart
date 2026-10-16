import 'package:flutter/material.dart';

/// 行内 Markdown 实时渲染的输入控制器（类似 Typora）：
/// **粗体**、*斜体*、`代码`、~~删除线~~、[链接](url)。标记符号淡化显示但保留可编辑。
class InlineMarkdownController extends TextEditingController {
  InlineMarkdownController({super.text});

  static final _re = RegExp(r'(\*\*[^*\n]+\*\*)|(\*[^*\n]+\*)|(`[^`\n]+`)|(~~[^~\n]+~~)|(\[[^\]\n]+\]\([^)\s]+\))');

  /// 光标所在位置的链接 URL（用于"打开链接"按钮）。
  String? linkAt(int offset) {
    for (final m in RegExp(r'\[([^\]\n]+)\]\(([^)\s]+)\)').allMatches(text)) {
      if (offset >= m.start && offset <= m.end) return m.group(2);
    }
    return null;
  }

  @override
  TextSpan buildTextSpan({required BuildContext context, TextStyle? style, required bool withComposing}) {
    final base = style ?? const TextStyle();
    final cs = Theme.of(context).colorScheme;
    final faded = base.copyWith(color: (base.color ?? cs.onSurface).withValues(alpha: 0.35));
    // 输入法组字期间不做样式处理，避免干扰中文输入
    if (withComposing && value.composing.isValid && !value.composing.isCollapsed) {
      return super.buildTextSpan(context: context, style: style, withComposing: withComposing);
    }
    final spans = <InlineSpan>[];
    var last = 0;
    for (final m in _re.allMatches(text)) {
      if (m.start > last) spans.add(TextSpan(text: text.substring(last, m.start)));
      final s = m.group(0)!;
      if (m.group(1) != null) {
        spans.addAll([
          TextSpan(text: '**', style: faded),
          TextSpan(text: s.substring(2, s.length - 2), style: const TextStyle(fontWeight: FontWeight.w700)),
          TextSpan(text: '**', style: faded),
        ]);
      } else if (m.group(2) != null) {
        spans.addAll([
          TextSpan(text: '*', style: faded),
          TextSpan(text: s.substring(1, s.length - 1), style: const TextStyle(fontStyle: FontStyle.italic)),
          TextSpan(text: '*', style: faded),
        ]);
      } else if (m.group(3) != null) {
        final code = TextStyle(
          fontFamily: 'monospace',
          color: cs.error,
          backgroundColor: cs.surfaceContainerHighest,
        );
        spans.addAll([
          TextSpan(text: '`', style: faded),
          TextSpan(text: s.substring(1, s.length - 1), style: code),
          TextSpan(text: '`', style: faded),
        ]);
      } else if (m.group(4) != null) {
        spans.addAll([
          TextSpan(text: '~~', style: faded),
          TextSpan(text: s.substring(2, s.length - 2), style: const TextStyle(decoration: TextDecoration.lineThrough)),
          TextSpan(text: '~~', style: faded),
        ]);
      } else {
        final close = s.indexOf('](');
        spans.addAll([
          TextSpan(text: '[', style: faded),
          TextSpan(
              text: s.substring(1, close),
              style: TextStyle(color: cs.primary, decoration: TextDecoration.underline, decorationColor: cs.primary)),
          TextSpan(text: s.substring(close), style: faded),
        ]);
      }
      last = m.end;
    }
    if (last < text.length) spans.add(TextSpan(text: text.substring(last)));
    return TextSpan(style: base, children: spans);
  }

  /// 用标记包裹选中文本（无选区时插入成对标记并把光标放中间）。
  void wrapSelection(String left, [String? right]) {
    right ??= left;
    final sel = selection;
    if (!sel.isValid) return;
    final t = text;
    final inner = sel.textInside(t);
    // 已包裹则取消
    if (sel.start >= left.length &&
        sel.end + right.length <= t.length &&
        t.substring(sel.start - left.length, sel.start) == left &&
        t.substring(sel.end, sel.end + right.length) == right) {
      final nt = t.replaceRange(sel.end, sel.end + right.length, '').replaceRange(sel.start - left.length, sel.start, '');
      value = TextEditingValue(
          text: nt, selection: TextSelection(baseOffset: sel.start - left.length, extentOffset: sel.end - left.length));
      return;
    }
    final nt = t.replaceRange(sel.start, sel.end, '$left$inner$right');
    value = TextEditingValue(
      text: nt,
      selection: inner.isEmpty
          ? TextSelection.collapsed(offset: sel.start + left.length)
          : TextSelection(baseOffset: sel.start + left.length, extentOffset: sel.end + left.length),
    );
  }

  void insertLink(String url) {
    final sel = selection;
    if (!sel.isValid) return;
    final label = sel.textInside(text).isEmpty ? '链接' : sel.textInside(text);
    final ins = '[$label]($url)';
    value = TextEditingValue(
        text: text.replaceRange(sel.start, sel.end, ins), selection: TextSelection.collapsed(offset: sel.start + ins.length));
  }
}

/// Markdown 快捷方式：在段落开头输入前缀即转换类型。返回 (类型名, 去掉前缀后的文本)。
(String, String)? detectShortcut(String text) {
  const map = {
    '# ': 'h1',
    '## ': 'h2',
    '### ': 'h3',
    '- ': 'bullet',
    '* ': 'bullet',
    '+ ': 'bullet',
    '1. ': 'numbered',
    '[] ': 'todo',
    '[ ] ': 'todo',
    '[x] ': 'todo_checked',
    '> ': 'quote',
    '>> ': 'toggle',
    '! ': 'callout',
    '```': 'code',
    '---': 'divider',
  };
  // 最长前缀优先
  final keys = map.keys.toList()..sort((a, b) => b.length.compareTo(a.length));
  for (final k in keys) {
    if (text.startsWith(k)) return (map[k]!, text.substring(k.length));
  }
  return null;
}
