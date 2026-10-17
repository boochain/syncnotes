import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/auth_api.dart';
import '../services/settings.dart';
import 'ds.dart';
import 'tokens.dart';

/// 保存文件：返回保存位置（取消返回 null）。测试中可替换。
typedef FileSaver = Future<String?> Function(String fileName, Uint8List bytes);

Future<String?> defaultFileSaver(String fileName, Uint8List bytes) async {
  final uri = await FilePicker.saveFile(fileName: fileName, bytes: bytes, dialogTitle: '保存 $fileName');
  if (uri == null) return null;
  if (uri.scheme == 'file') {
    // 部分桌面平台只返回路径不写入内容：补写一次。
    final f = File(uri.toFilePath());
    if (!await f.exists() || await f.length() == 0) await f.writeAsBytes(bytes, flush: true);
    return f.path;
  }
  return uri.toString();
}

/// 当前使用的保存实现（测试中替换为假实现）。
FileSaver fileSaver = defaultFileSaver;

String recoveryCodeFileText(String username, String server, String code) => '''SyncNotes 恢复码
================
用户名：$username
服务器：$server
恢复码：$code
生成时间：${DateTime.now().toString().substring(0, 16)}

忘记密码时，在登录页点「忘记密码？」，输入用户名、此恢复码和新密码即可重置。
· 恢复码只能使用一次，使用后会生成新的恢复码。
· 任何拿到此恢复码的人都能重置你的密码，请妥善保管（建议打印或存入密码管理器），不要发给别人。
''';

/// 分组输入行（与登录页一致：高 44，20 图标位 + 无边框输入框）。
class GroupedField extends StatelessWidget {
  final TextEditingController controller;
  final IconData icon;
  final String hint;
  final bool obscure;
  final bool mono;
  final ValueChanged<String>? onSubmitted;
  final TextInputAction? action;
  const GroupedField(
      {super.key,
      required this.controller,
      required this.icon,
      required this.hint,
      this.obscure = false,
      this.mono = false,
      this.onSubmitted,
      this.action});

  @override
  Widget build(BuildContext context) {
    final pal = AppColors.of(context);
    final base = Theme.of(context).textTheme.bodyMedium;
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: Sizes.bar),
      child: Row(children: [
        const SizedBox(width: Gap.l),
        SizedBox.square(dimension: Sizes.iconMd, child: Icon(icon, size: Sizes.iconMd - 2, color: pal.text2)),
        const SizedBox(width: Gap.l),
        Expanded(
          child: TextField(
            controller: controller,
            obscureText: obscure,
            onSubmitted: onSubmitted,
            textInputAction: action,
            autocorrect: false,
            enableSuggestions: !obscure && !mono,
            textCapitalization: mono ? TextCapitalization.characters : TextCapitalization.none,
            style: mono ? base?.copyWith(fontFamily: FontTokens.mono, fontFamilyFallback: FontTokens.monoFallback) : base,
            decoration: InputDecoration.collapsed(hintText: hint).copyWith(filled: false, semanticCounterText: hint),
          ),
        ),
        const SizedBox(width: Gap.l),
      ]),
    );
  }
}

/// 分组卡片：圆角 + 细边框，行之间细分隔线。
class GroupedCard extends StatelessWidget {
  final List<Widget> children;
  const GroupedCard({super.key, required this.children});
  @override
  Widget build(BuildContext context) {
    final pal = AppColors.of(context);
    final divider = Divider(height: 1, thickness: 1, indent: Gap.l + Sizes.iconMd + Gap.l, color: pal.separator);
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: pal.elevated,
        borderRadius: BorderRadius.circular(AppRadius.l),
        border: Border.all(color: pal.separator),
      ),
      child: Column(children: [
        for (var i = 0; i < children.length; i++) ...[if (i > 0) divider, children[i]],
      ]),
    );
  }
}

/// 提示条（警告 / 说明）。
class NoticeBox extends StatelessWidget {
  final IconData icon;
  final String text;
  final Color color;
  const NoticeBox({super.key, required this.icon, required this.text, required this.color});
  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.all(Gap.m),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppRadius.m),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, size: Sizes.iconSm, color: color),
        const SizedBox(width: Gap.s),
        Expanded(child: Text(text, style: tt.bodySmall?.copyWith(color: AppColors.of(context).text))),
      ]),
    );
  }
}

// ---------------------------------------------------------------- 恢复码对话框

/// 只显示一次的恢复码：复制、保存到文件、明确警告；勾选“已保存”后才能关闭。
Future<void> showRecoveryCodeDialog(BuildContext context,
    {required String code, required String username, required String server}) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => RecoveryCodeDialog(code: code, username: username, server: server),
  );
}

class RecoveryCodeDialog extends StatefulWidget {
  final String code;
  final String username;
  final String server;
  const RecoveryCodeDialog({super.key, required this.code, required this.username, required this.server});
  @override
  State<RecoveryCodeDialog> createState() => _RecoveryCodeDialogState();
}

class _RecoveryCodeDialogState extends State<RecoveryCodeDialog> {
  bool _ack = false;

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.code));
    if (mounted) showToast(context, '恢复码已复制');
  }

  Future<void> _save() async {
    final bytes = Uint8List.fromList(utf8.encode(recoveryCodeFileText(widget.username, widget.server, widget.code)));
    try {
      final where = await fileSaver('SyncNotes-恢复码-${widget.username}.txt', bytes);
      if (where != null && mounted) {
        setState(() => _ack = true);
        showToast(context, '已保存到 $where');
      }
    } catch (e) {
      if (mounted) showToast(context, '保存失败：$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final pal = AppColors.of(context);
    final tt = Theme.of(context).textTheme;
    return PopScope(
      canPop: false,
      child: AlertDialog(
        key: const Key('recoveryCodeDialog'),
        title: const Text('请保存你的恢复码'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 400),
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text('忘记密码时，用它在登录页「忘记密码？」中重置密码。', style: tt.bodyMedium?.copyWith(color: pal.text2)),
              const SizedBox(height: Gap.l),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: Gap.m, vertical: Gap.l),
                decoration: BoxDecoration(color: pal.fill, borderRadius: BorderRadius.circular(AppRadius.m)),
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: SelectableText(
                    widget.code,
                    key: const Key('recoveryCodeText'),
                    textAlign: TextAlign.center,
                    style: tt.titleMedium?.copyWith(
                        fontFamily: FontTokens.mono,
                        fontFamilyFallback: FontTokens.monoFallback,
                        letterSpacing: 1.5,
                        fontWeight: FontWeight.w600),
                  ),
                ),
              ),
              const SizedBox(height: Gap.m),
              Row(children: [
                Expanded(
                  child: OutlinedButton.icon(
                    key: const Key('copyRecoveryCode'),
                    style: OutlinedButton.styleFrom(minimumSize: const Size(0, Sizes.control)),
                    icon: const Icon(CupertinoIcons.doc_on_doc, size: Sizes.iconSm),
                    label: const Text('复制'),
                    onPressed: _copy,
                  ),
                ),
                const SizedBox(width: Gap.s),
                Expanded(
                  child: OutlinedButton.icon(
                    key: const Key('saveRecoveryCode'),
                    style: OutlinedButton.styleFrom(minimumSize: const Size(0, Sizes.control)),
                    icon: const Icon(CupertinoIcons.arrow_down_doc, size: Sizes.iconSm),
                    label: const Text('保存到文件'),
                    onPressed: _save,
                  ),
                ),
              ]),
              const SizedBox(height: Gap.l),
              NoticeBox(
                icon: CupertinoIcons.exclamationmark_triangle_fill,
                color: pal.warning,
                text: '恢复码只显示这一次，关闭后无法再查看。它只能使用一次；'
                    '任何拿到它的人都能重置你的密码，请勿发给别人。丢失后可在「设置 → 账号」重新生成。',
              ),
              const SizedBox(height: Gap.s),
              InkWell(
                key: const Key('recoveryAck'),
                borderRadius: BorderRadius.circular(AppRadius.s),
                onTap: () => setState(() => _ack = !_ack),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: Sizes.bar),
                  child: Row(children: [
                    Checkbox(value: _ack, onChanged: (v) => setState(() => _ack = v ?? false)),
                    Expanded(child: Text('我已妥善保存恢复码', style: tt.bodyMedium)),
                  ]),
                ),
              ),
            ]),
          ),
        ),
        actions: [
          FilledButton(
            key: const Key('recoveryDone'),
            onPressed: _ack ? () => Navigator.of(context).pop() : null,
            child: const Text('完成'),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- 修改密码 / 生成恢复码

String? _pwError(String a, String b) {
  if (a.characters.length < 4) return '新密码至少 4 位';
  if (a != b) return '两次输入的新密码不一致';
  return null;
}

/// 修改密码。`forced` = 管理员重置后的临时密码：不能跳过（取消 = 返回登录页）。
/// 成功返回新密码。
Future<String?> showChangePasswordDialog(BuildContext context,
    {required AuthApi api, required String server, required String token, String? oldPassword, bool forced = false}) {
  return showDialog<String>(
    context: context,
    barrierDismissible: !forced,
    builder: (_) => _ChangePasswordDialog(api: api, server: server, token: token, oldPassword: oldPassword, forced: forced),
  );
}

class _ChangePasswordDialog extends StatefulWidget {
  final AuthApi api;
  final String server, token;
  final String? oldPassword;
  final bool forced;
  const _ChangePasswordDialog({required this.api, required this.server, required this.token, this.oldPassword, required this.forced});
  @override
  State<_ChangePasswordDialog> createState() => _ChangePasswordDialogState();
}

class _ChangePasswordDialogState extends State<_ChangePasswordDialog> {
  late final _old = TextEditingController(text: widget.oldPassword ?? '');
  final _new1 = TextEditingController();
  final _new2 = TextEditingController();
  String? _error;
  bool _busy = false;

  Future<void> _submit() async {
    final e = _pwError(_new1.text, _new2.text);
    if (e != null) return setState(() => _error = e);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.api.changePassword(widget.server, widget.token, _old.text, _new1.text);
      if (mounted) Navigator.of(context).pop(_new1.text);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final pal = AppColors.of(context);
    final tt = Theme.of(context).textTheme;
    return PopScope(
      canPop: !widget.forced,
      child: AlertDialog(
        key: const Key('changePasswordDialog'),
        title: Text(widget.forced ? '请设置新密码' : '修改密码'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 400),
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              if (widget.forced) ...[
                NoticeBox(
                  icon: CupertinoIcons.lock_shield,
                  color: pal.accent,
                  text: '管理员已为你重置密码。设置新密码后即可继续同步，你的笔记和文件都在。',
                ),
                const SizedBox(height: Gap.l),
              ],
              GroupedCard(children: [
                if (widget.oldPassword == null)
                  GroupedField(key: const Key('oldPasswordField'), controller: _old, icon: CupertinoIcons.lock, hint: '当前密码', obscure: true),
                GroupedField(key: const Key('newPasswordField'), controller: _new1, icon: CupertinoIcons.lock_rotation, hint: '新密码（至少 4 位）', obscure: true),
                GroupedField(
                    key: const Key('confirmPasswordField'),
                    controller: _new2,
                    icon: CupertinoIcons.checkmark_shield,
                    hint: '再次输入新密码',
                    obscure: true,
                    onSubmitted: (_) => _submit()),
              ]),
              if (_error != null) ...[
                const SizedBox(height: Gap.m),
                Text(_error!, key: const Key('changePasswordError'), style: tt.bodySmall?.copyWith(color: pal.danger)),
              ],
            ]),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(widget.forced ? '返回登录' : '取消')),
          FilledButton(key: const Key('changePasswordSubmit'), onPressed: _busy ? null : _submit, child: const Text('确定')),
        ],
      ),
    );
  }
}

/// 询问当前密码（用于生成恢复码的二次确认）。
Future<String?> _askPassword(BuildContext context) {
  final c = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (d) => AlertDialog(
      title: const Text('验证当前密码'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 400),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('生成新的恢复码后，旧恢复码立即失效。', style: Theme.of(d).textTheme.bodyMedium?.copyWith(color: AppColors.of(d).text2)),
          const SizedBox(height: Gap.l),
          GroupedCard(children: [
            GroupedField(
                key: const Key('verifyPasswordField'),
                controller: c,
                icon: CupertinoIcons.lock,
                hint: '当前密码',
                obscure: true,
                onSubmitted: (v) => Navigator.pop(d, v)),
          ]),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(d), child: const Text('取消')),
        FilledButton(key: const Key('verifyPasswordSubmit'), onPressed: () => Navigator.pop(d, c.text), child: const Text('生成')),
      ],
    ),
  );
}

/// 设置 → 账号 → 生成/重置恢复码。`password` 已知时（刚登录）不再询问。
Future<bool> generateRecoveryCodeFlow(BuildContext context,
    {required AuthApi api, required String server, required String token, required String username, String? password}) async {
  final pw = password ?? await _askPassword(context);
  if (pw == null || pw.isEmpty || !context.mounted) return false;
  try {
    final code = await api.regenerateRecoveryCode(server, token, pw);
    if (!context.mounted) return false;
    await showRecoveryCodeDialog(context, code: code, username: username, server: server);
    return true;
  } catch (e) {
    if (context.mounted) showToast(context, '生成失败：$e');
    return false;
  }
}

bool legacyPromptShown(Settings s, String user) => s.prefs.getBool('recovery_prompted_$user') ?? false;
void markLegacyPromptShown(Settings s, String user) => s.prefs.setBool('recovery_prompted_$user', true);

/// 旧账号首次登录：提示生成恢复码（只提示一次）。
Future<bool> askGenerateLegacyCode(BuildContext context) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (d) => AlertDialog(
      key: const Key('legacyRecoveryPrompt'),
      title: const Text('生成恢复码？'),
      content: const Text('你的账号还没有恢复码。忘记密码时，恢复码是自助找回账号的唯一方式（服务器没有邮箱找回）。'
          '\n\n以后也可以在「设置 → 账号」生成。'),
      actions: [
        TextButton(key: const Key('legacyLater'), onPressed: () => Navigator.pop(d, false), child: const Text('以后再说')),
        FilledButton(key: const Key('legacyGenerate'), onPressed: () => Navigator.pop(d, true), child: const Text('立即生成')),
      ],
    ),
  );
  return ok == true;
}

// ---------------------------------------------------------------- 忘记密码页

/// 登录页「忘记密码？」：用户名 + 恢复码 + 新密码。成功后 pop 出 [AuthResult]（已显示过新恢复码）。
class ForgotPasswordPage extends StatefulWidget {
  final AuthApi api;
  final String server;
  final String username;
  final String deviceId;
  final String? deviceName;
  const ForgotPasswordPage(
      {super.key, required this.api, required this.server, required this.username, required this.deviceId, this.deviceName});
  @override
  State<ForgotPasswordPage> createState() => _ForgotPasswordPageState();
}

class _ForgotPasswordPageState extends State<ForgotPasswordPage> {
  late final _server = TextEditingController(text: widget.server);
  late final _user = TextEditingController(text: widget.username);
  final _code = TextEditingController();
  final _pw1 = TextEditingController();
  final _pw2 = TextEditingController();
  String? _error;
  bool _busy = false;

  Future<void> _submit() async {
    final server = _server.text.trim(), user = _user.text.trim(), code = _code.text.trim();
    if (server.isEmpty || user.isEmpty || code.isEmpty) {
      return setState(() => _error = '请填写服务器地址、用户名和恢复码');
    }
    final e = _pwError(_pw1.text, _pw2.text);
    if (e != null) return setState(() => _error = e);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final r = await widget.api.recover(server, user, code, _pw1.text, widget.deviceId, deviceName: widget.deviceName);
      if (!mounted) return;
      setState(() => _busy = false);
      if (r.recoveryCode != null) {
        await showRecoveryCodeDialog(context, code: r.recoveryCode!, username: r.username, server: server);
      }
      if (mounted) Navigator.of(context).pop((r, server));
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final pal = AppColors.of(context);
    final tt = Theme.of(context).textTheme;
    return Scaffold(
      backgroundColor: pal.bg,
      appBar: AppBar(title: const Text('忘记密码')),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(Gap.x3),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text('用恢复码重置密码', textAlign: TextAlign.center, style: tt.titleLarge),
              const SizedBox(height: Gap.xs),
              Text('重置后所有设备需要重新登录，笔记、文件和回收站都不受影响。',
                  textAlign: TextAlign.center, style: tt.bodyMedium?.copyWith(color: pal.text2)),
              const SizedBox(height: Gap.xxl),
              GroupedCard(key: const Key('forgotForm'), children: [
                GroupedField(key: const Key('forgotServerField'), controller: _server, icon: CupertinoIcons.globe, hint: '服务器地址'),
                GroupedField(key: const Key('forgotUserField'), controller: _user, icon: CupertinoIcons.person, hint: '用户名'),
                GroupedField(
                    key: const Key('recoveryCodeField'),
                    controller: _code,
                    icon: CupertinoIcons.number,
                    hint: '恢复码，如 ABCDE-FGHIJ-KLMNO-PQRST',
                    mono: true),
                GroupedField(key: const Key('forgotNewPassword'), controller: _pw1, icon: CupertinoIcons.lock, hint: '新密码（至少 4 位）', obscure: true),
                GroupedField(
                    key: const Key('forgotConfirmPassword'),
                    controller: _pw2,
                    icon: CupertinoIcons.checkmark_shield,
                    hint: '再次输入新密码',
                    obscure: true,
                    onSubmitted: (_) => _submit()),
              ]),
              AnimatedSwitcher(
                duration: Motion.short4,
                child: _error == null
                    ? const SizedBox(height: Gap.xxl)
                    : Padding(
                        padding: const EdgeInsets.symmetric(vertical: Gap.m),
                        child: Text(_error!,
                            key: const Key('forgotError'), textAlign: TextAlign.center, style: tt.bodySmall?.copyWith(color: pal.danger)),
                      ),
              ),
              FilledButton(
                key: const Key('resetPasswordButton'),
                onPressed: _busy ? null : _submit,
                style: FilledButton.styleFrom(fixedSize: const Size.fromHeight(Sizes.bar), minimumSize: const Size.fromHeight(Sizes.bar)),
                child: _busy
                    ? const SizedBox.square(dimension: Sizes.iconSm, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Text('重置密码并登录'),
              ),
              const SizedBox(height: Gap.xl),
              NoticeBox(
                icon: CupertinoIcons.question_circle,
                color: pal.text2,
                text: '恢复码丢失？请联系服务器管理员在服务器上运行：\nsudo ./syncnotes-server.sh reset-password 你的用户名\n'
                    '（或菜单「忘记密码 / 数据救援」）。数据不会丢失。',
              ),
            ]),
          ),
        ),
      ),
    );
  }
}
