import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'desktop.dart';
import 'library.dart';
import 'scope.dart';

const appVersion = '1.5.0';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final s = Scope.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        children: [
          ListTile(title: const Text('服务器'), subtitle: Text(s.server ?? '')),
          ListTile(title: const Text('用户'), subtitle: Text(s.username ?? '')),
          if (s.knownServers.isNotEmpty) const ListTile(title: Text('记住的服务器')),
          for (final host in s.knownServers)
            ListTile(
              title: Text(host),
              trailing: IconButton(tooltip: '删除', onPressed: () => s.forgetServer(host), icon: const Icon(Icons.close)),
              onTap: () => s.rememberServer(host),
            ),
          const ListTile(title: Text('外观')),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'system', label: Text('系统')),
                ButtonSegment(value: 'light', label: Text('浅色')),
                ButtonSegment(value: 'dark', label: Text('深色')),
              ],
              selected: {s.themeMode},
              onSelectionChanged: (v) => s.themeMode = v.first,
            ),
          ),
          const ListTile(title: Text('背景'), subtitle: Text('铺在界面后面。透明度只作用在卡片上，窗口本身不透明，避免页面叠在一起。')),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Wrap(spacing: 8, children: [
              for (final item in const [('default', '默认'), ('ocean', '海蓝'), ('dusk', '暮色'), ('paper', '纸色'), ('ink', '墨色')])
                ChoiceChip(
                  label: Text(item.$2),
                  selected: s.backdrop == item.$1,
                  onSelected: (_) => s.backdrop = item.$1,
                ),
            ]),
          ),
          ListTile(
            title: const Text('卡片透明度'),
            subtitle: Slider(
              value: s.surfaceOpacity,
              min: 0.72,
              max: 1,
              onChanged: (v) => s.surfaceOpacity = v,
            ),
          ),
          const ListTile(title: Text('字号')),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: SegmentedButton<double>(
              segments: const [
                ButtonSegment(value: 1, label: Text('标准')),
                ButtonSegment(value: 1.15, label: Text('大')),
                ButtonSegment(value: 1.3, label: Text('更大')),
              ],
              selected: {s.textScale},
              onSelectionChanged: (v) => s.textScale = v.first,
            ),
          ),
          if (Platform.isWindows)
            SwitchListTile(
              title: const Text('关闭窗口时收到托盘'),
              subtitle: const Text('关掉后程序还在。托盘菜单可以打开或退出。'),
              value: s.closeToTray,
              onChanged: (v) async {
                s.closeToTray = v;
                await Desk.setCloseToTray(v);
              },
            ),
          const SizedBox(height: 12),
          if (isDesktop)
            ListTile(
              title: Text(s.windowExpanded ? '收起为小窗' : '展开窗口'),
              onTap: () async {
                final next = !s.windowExpanded;
                s.windowExpanded = next;
                await Desk.toggle(next);
              },
            ),
          ListTile(
            title: Text(s.hasPin ? '关掉应用锁' : '设置应用锁'),
            subtitle: const Text('离开应用再回来时要先输入，和登录密码不是同一个'),
            onTap: () => _pin(context, s),
          ),
          ListTile(
            title: const Text('修改登录密码'),
            subtitle: const Text('会用新密码把每篇笔记和文件重新加密，然后才能换。期间不要关掉。'),
            onTap: () => _rekey(context, s),
          ),
          ListTile(
            title: const Text('剪藏网页'),
            subtitle: const Text('粘贴网址，把正文收成一篇笔记'),
            onTap: () => _clip(context, s),
          ),
          ListTile(
            title: const Text('接收别人的分享'),
            subtitle: const Text('填分享编号和对方给的分享密码'),
            onTap: () => _receive(context, s),
          ),
          ListTile(
            title: const Text('浏览器剪藏书签'),
            subtitle: const SelectableText(bookmarklet),
          ),
          ListTile(
            title: const Text('重传本地缓存'),
            subtitle: const Text('把这台设备上的笔记再发给服务器。时间不改。服务器上更新的不会被盖掉，缺的会补上。'),
            onTap: () async {
              final n = await s.resendLocal();
              if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('已重传 $n 篇')));
            },
          ),
          ListTile(
            title: const Text('导出全部笔记'),
            subtitle: const Text('存成一个 Markdown 文件，方便自己备份'),
            onTap: () async {
              final file = await s.exportNotesFile();
              if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('已写到 ${file.path}')));
            },
          ),
          ListTile(
            title: const Text('导入 Markdown'),
            subtitle: const Text('选一个 .md，变成一篇新笔记'),
            onTap: () async {
              final picked = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: ['md', 'txt', 'markdown']);
              if (picked.isEmpty) return;
              final f = picked.first;
              final path = f.path;
              if (path == null) return;
              final text = await File(path).readAsString();
              final title = f.name.replaceAll(RegExp(r'\.(md|txt|markdown)$'), '');
              s.create(title: title, body: text);
              if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('已导入 $title')));
            },
          ),
          ListTile(
            title: const Text('退出登录'),
            onTap: () async {
              final ok = await showDialog<bool>(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text('退出登录'),
                  content: const Text('这台设备上记住的钥匙会清掉。笔记还在服务器上，用同一个密码可以再进来。'),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
                    FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('退出')),
                  ],
                ),
              );
              if (ok != true) return;
              await s.logout();
              if (context.mounted) Navigator.of(context).popUntil((r) => r.isFirst);
            },
          ),
          const ListTile(title: Text('版本'), subtitle: Text(appVersion)),
          ListTile(
            title: const Text('服务器指纹'),
            subtitle: Text(s.server == null
                ? '还没连接'
                : '当前 ${s.fingerprintFor(s.server!) ?? '这台服务器还没有指纹（多半是旧版）'}'),
          ),
          const ListTile(
            title: Text('指纹是干什么的'),
            subtitle: Text('它是这台服务器数据库的编号，存在服务器自己的库里。用来发现你是不是连上了另一台同地址的机器。它不是密码，解不开笔记，也不参与加密。编号变了，只说明数据库被换过或重装过。确认是你自己的之后，点记住即可。'),
          ),
          const ListTile(
            title: Text('哪些是加密的'),
            subtitle: Text('加密后才离开设备：笔记标题、正文、标签、文件夹、颜色、评论、历史、附件内容。\n明文：用户名、服务器地址、同步时间、文件在服务器上的编号。登录和传输需要这些。\nhttps / wss 再加一层传输加密。用 http 时传输层是明文，笔记本身仍是密文。\n分享给别人时，用另一把分享密码再封一次，服务器看不到正文。'),
          ),
        ],
      ),
    );
  }
}

Future<void> _pin(BuildContext context, dynamic s) async {
  final pin = TextEditingController();
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(s.hasPin ? '关掉应用锁' : '设置应用锁'),
      content: TextField(controller: pin, obscureText: true, decoration: const InputDecoration(labelText: '应用锁，至少 4 位')),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('确定')),
      ],
    ),
  );
  final value = pin.text;
  pin.dispose();
  if (ok != true || !context.mounted) return;
  try {
    if (s.hasPin) {
      await s.clearPin(value);
    } else {
      if (value.length < 4) throw Exception('至少 4 位');
      await s.setPin(value);
    }
  } catch (e) {
    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
  }
}

Future<void> _rekey(BuildContext context, dynamic s) async {
  final current = TextEditingController();
  final next = TextEditingController();
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('修改登录密码'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        const Text('改完之后，其他设备要用新密码才能解开笔记。'),
        TextField(controller: current, obscureText: true, decoration: const InputDecoration(labelText: '现在的密码')),
        TextField(controller: next, obscureText: true, decoration: const InputDecoration(labelText: '新密码')),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('开始')),
      ],
    ),
  );
  final a = current.text;
  final b = next.text;
  current.dispose();
  next.dispose();
  if (ok != true || !context.mounted) return;
  try {
    await s.changePassword(a, b);
    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('密码已更换，笔记已用新密码重新加密')));
  } catch (e) {
    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
  }
}

Future<void> _clip(BuildContext context, dynamic s) async {
  final url = TextEditingController();
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('剪藏网页'),
      content: TextField(controller: url, decoration: const InputDecoration(labelText: '网址')),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('收取')),
      ],
    ),
  );
  final raw = url.text.trim();
  url.dispose();
  if (ok != true || raw.isEmpty || !context.mounted) return;
  try {
    final res = await http.get(Uri.parse(raw)).timeout(const Duration(seconds: 20));
    final text = readableText(res.body);
    final title = text.split('\n').first;
    s.create(title: title, body: clipMarkdown(url: raw, title: title, text: text));
    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已收成一篇笔记')));
  } catch (e) {
    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('没收下来：$e')));
  }
}

Future<void> _receive(BuildContext context, dynamic s) async {
  final id = TextEditingController();
  final pass = TextEditingController();
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('接收分享'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(controller: id, decoration: const InputDecoration(labelText: '分享编号')),
        TextField(controller: pass, obscureText: true, decoration: const InputDecoration(labelText: '分享密码')),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('打开')),
      ],
    ),
  );
  final shareId = id.text;
  final secret = pass.text;
  id.dispose();
  pass.dispose();
  if (ok != true || !context.mounted) return;
  try {
    final note = await s.importShare(shareId, secret);
    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('已放入「${note.heading}」')));
  } catch (e) {
    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
  }
}
