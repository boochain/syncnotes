import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'doc.dart';

/// "/" 菜单中的一项
class SlashCommand {
  final String label;
  final String hint;
  final IconData icon;
  final List<String> keywords;
  final DocType? type;

  /// 特殊命令：'page' 创建子页面
  final String? special;
  const SlashCommand(this.label, this.hint, this.icon, this.keywords, {this.type, this.special});

  bool matches(String q) {
    if (q.isEmpty) return true;
    final l = q.toLowerCase();
    return label.contains(q) || keywords.any((k) => k.startsWith(l));
  }
}

const slashCommands = <SlashCommand>[
  SlashCommand('文本', '普通段落', CupertinoIcons.text_alignleft, ['text', 'paragraph', 'p', 'wb'], type: DocType.paragraph),
  SlashCommand('一级标题', '#  大标题', CupertinoIcons.textformat_size, ['h1', 'heading1', 'bt'], type: DocType.h1),
  SlashCommand('二级标题', '##  中标题', CupertinoIcons.textformat_size, ['h2', 'heading2'], type: DocType.h2),
  SlashCommand('三级标题', '###  小标题', CupertinoIcons.textformat_size, ['h3', 'heading3'], type: DocType.h3),
  SlashCommand('项目符号列表', '-  无序列表', CupertinoIcons.list_bullet, ['bullet', 'list', 'ul', 'lb'], type: DocType.bullet),
  SlashCommand('编号列表', '1.  有序列表', CupertinoIcons.list_number, ['numbered', 'ol', 'number', 'bh'], type: DocType.numbered),
  SlashCommand('待办事项', '[]  复选框', CupertinoIcons.checkmark_square, ['todo', 'task', 'check', 'db'], type: DocType.todo),
  SlashCommand('折叠列表', '>>  可展开收起', CupertinoIcons.arrowtriangle_right_fill, ['toggle', 'collapse', 'zd'], type: DocType.toggle),
  SlashCommand('引用', '>  引用文字', CupertinoIcons.text_quote, ['quote', 'blockquote', 'yy'], type: DocType.quote),
  SlashCommand('标注', '!  醒目提示框', CupertinoIcons.lightbulb, ['callout', 'note', 'tip', 'bz'], type: DocType.callout),
  SlashCommand('代码', '```  语法高亮', CupertinoIcons.chevron_left_slash_chevron_right, ['code', 'snippet', 'dm'], type: DocType.code),
  SlashCommand('分割线', '---', CupertinoIcons.minus, ['divider', 'hr', 'line', 'fgx'], type: DocType.divider),
  SlashCommand('图片', '上传或链接', CupertinoIcons.photo, ['image', 'img', 'picture', 'tp'], type: DocType.image),
  SlashCommand('子页面', '在此页面内新建页面', CupertinoIcons.doc_text, ['page', 'subpage', 'ym'], special: 'page'),
];

List<SlashCommand> filterCommands(String q) => slashCommands.where((c) => c.matches(q)).toList();

IconData iconForType(DocType t) => slashCommands.firstWhere((c) => c.type == t).icon;
String labelForType(DocType t) => slashCommands.firstWhere((c) => c.type == t).label;

const codeLanguages = [
  'plaintext', 'dart', 'python', 'javascript', 'typescript', 'rust', 'go', 'java', 'kotlin', 'c', 'cpp', 'csharp',
  'bash', 'json', 'yaml', 'sql', 'html', 'css', 'markdown',
];
