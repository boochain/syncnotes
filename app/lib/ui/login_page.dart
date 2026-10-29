import 'ds.dart';
import 'dart:io';
import 'tokens.dart';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../services/auth_api.dart';
import '../services/discovery.dart';
import '../services/settings.dart';
import '../sync/wire_seal.dart';
import 'motion.dart';
import 'recovery_ui.dart';

/// 登录 / 注册页面。支持手动输入服务器地址或局域网发现。
class LoginPage extends StatefulWidget {
  final Settings settings;
  final AuthApi api;
  final void Function() onLoggedIn;
  const LoginPage({super.key, required this.settings, required this.api, required this.onLoggedIn});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  late final TextEditingController _server =
      TextEditingController(text: widget.settings.server ?? '');
  late final TextEditingController _user =
      TextEditingController(text: widget.settings.username ?? '');
  final _pw = TextEditingController();
  bool _busy = false;
  late bool _remember;

  @override
  void initState() {
    super.initState();
    _remember = widget.settings.rememberPassword;
    if (_remember) _pw.text = widget.settings.savedPassword ?? '';
  }

  @override
  void dispose() {
    _server.dispose();
    _user.dispose();
    _pw.dispose();
    super.dispose();
  }
  bool _registerMode = false;
  bool _discovering = false;
  String? _error;
  bool _pinMismatch = false;
  List<DiscoveredServer> _found = [];

  Future<void> _submit() async {
    final server = normalizeServer(_server.text);
    if (server.isEmpty || _user.text.trim().isEmpty || _pw.text.isEmpty) {
      setState(() => _error = '请填写服务器地址、用户名和密码');
      return;
    }
    if (_server.text != server) _server.text = server;
    setState(() {
      _busy = true;
      _error = null;
      _pinMismatch = false;
    });
    try {
      String? newCode;
      if (_registerMode) {
        newCode = await widget.api.register(server, _user.text.trim(), _pw.text);
      }
      final r = await widget.api.login(
          server, _user.text.trim(), _pw.text, widget.settings.deviceId,
          deviceName: _deviceName());
      if (!mounted) return;
      setState(() => _busy = false); // 对话框期间不显示转圈
      if (r.mustChangePassword) {
        // 管理员重置的临时密码：先改密码才能同步（取消则留在登录页）
        final changed = await showChangePasswordDialog(context,
            api: widget.api, server: server, token: r.token, oldPassword: _pw.text, forced: true);
        if (changed == null || !mounted) return;
      }
      if (newCode != null) {
        await showRecoveryCodeDialog(context, code: newCode, username: r.username, server: server);
      } else if (!r.hasRecoveryCode && !legacyPromptShown(widget.settings, r.username)) {
        markLegacyPromptShown(widget.settings, r.username);
        if (mounted && await askGenerateLegacyCode(context) && mounted) {
          await generateRecoveryCodeFlow(context,
              api: widget.api, server: server, token: r.token, username: r.username, password: _pw.text);
        }
      }
      if (!mounted) return;
      _finishLogin(server, r);
    } catch (e) {
      setState(() {
        _pinMismatch = e is SealPinMismatch;
        _error = '$e';
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _finishLogin(String server, AuthResult r) {
    widget.settings
      ..server = server
      ..username = r.username
      ..token = r.token
      ..rememberPassword = _remember
      ..savedPassword = _remember ? _pw.text : null
      ..rememberServer(server);
    widget.onLoggedIn();
  }

  Future<void> _trustNewPin() async {
    final server = _server.text.trim();
    widget.settings.clearSealPin(server);
    WireSeal.forget(server);
    await _submit();
  }

  Future<void> _forgot() async {
    final res = await Navigator.of(context).push<(AuthResult, String)>(MaterialPageRoute(
      builder: (_) => ForgotPasswordPage(
        api: widget.api,
        settings: widget.settings,
        server: _server.text.trim(),
        username: _user.text.trim(),
        deviceId: widget.settings.deviceId,
        deviceName: _deviceName(),
      ),
    ));
    if (res != null && mounted) _finishLogin(res.$2, res.$1);
  }

  String _deviceName() {
    try {
      return '${Platform.operatingSystem} ${Platform.localHostname}';
    } catch (_) {
      return 'unknown';
    }
  }

  Future<void> _discover() async {
    setState(() {
      _discovering = true;
      _found = [];
    });
    final r = await discoverLanServers();
    if (!mounted) return;
    setState(() {
      _discovering = false;
      _found = r;
      if (r.isEmpty) _error = '未发现局域网服务器，请手动输入地址';
      if (r.length == 1) _server.text = r.first.address;
    });
  }

  /// HIG 分组输入行：高 44，20 图标位 + 输入框，多行之间用细分隔线（iOS 登录表单样式）
  Widget _row(BuildContext context, {required Key key, required TextEditingController c, required IconData icon,
      required String hint, bool obscure = false, Widget? suffix, ValueChanged<String>? onSubmitted, String? label}) {
    final pal = AppColors.of(context);
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: Sizes.bar),
      child: Row(children: [
        const SizedBox(width: Gap.l),
        SizedBox.square(dimension: Sizes.iconMd, child: Icon(icon, size: Sizes.iconMd - 2, color: pal.text2)),
        const SizedBox(width: Gap.l),
        Expanded(
          child: TextField(
            key: key,
            controller: c,
            obscureText: obscure,
            onSubmitted: onSubmitted,
            style: Theme.of(context).textTheme.bodyMedium,
            decoration: InputDecoration.collapsed(hintText: hint).copyWith(filled: false, semanticCounterText: label),
          ),
        ),
        // 行高固定 44：触屏 48 点击区只向宽度扩展，不把这一行撑高（同列各行等高）
        if (suffix != null) SizedBox(height: Sizes.bar, child: Center(child: suffix)),
        const SizedBox(width: Gap.xs),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final pal = AppColors.of(context);
    final tt = Theme.of(context).textTheme;
    final divider = Divider(height: 1, thickness: 1, indent: Gap.l + Sizes.iconMd + Gap.l, color: pal.separator);
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(Gap.x3),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              // 应用图标：HIG 圆角方形，纯强调色（不再用渐变与彩色阴影）
              Center(
                child: Container(
                  key: const Key('appMark'),
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(borderRadius: BorderRadius.circular(13), color: pal.accent),
                  child: const Icon(CupertinoIcons.arrow_2_squarepath, color: Colors.white, size: 28),
                ),
              ),
              const SizedBox(height: Gap.xl),
              Text('SyncNotes', textAlign: TextAlign.center, style: tt.headlineSmall),
              const SizedBox(height: Gap.xs),
              Text('多设备实时同步的笔记与消息', textAlign: TextAlign.center, style: tt.bodyMedium?.copyWith(color: pal.text2)),
              const SizedBox(height: Gap.x4 - Gap.xs),
              Container(
                key: const Key('loginForm'),
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  color: pal.elevated,
                  borderRadius: BorderRadius.circular(AppRadius.l),
                  border: Border.all(color: pal.separator),
                ),
                child: Column(children: [
                  _row(context,
                      key: const Key('serverField'),
                      c: _server,
                      icon: CupertinoIcons.globe,
                      hint: '域名自动加 https，IP 自动加 http',
                      label: '服务器地址',
                      suffix: _discovering
                          ? const SizedBox.square(
                              dimension: Sizes.control,
                              child: Center(child: SizedBox.square(dimension: Sizes.iconSm, child: CircularProgressIndicator(strokeWidth: 2))))
                          : IconButton(
                              key: const Key('discoverButton'),
                              tooltip: '搜索局域网服务器',
                              icon: Icon(CupertinoIcons.wifi, size: Sizes.iconMd - 2, color: pal.accent),
                              onPressed: _discover)),
                  divider,
                  _row(context, key: const Key('userField'), c: _user, icon: CupertinoIcons.person, hint: '用户名'),
                  divider,
                  _row(context,
                      key: const Key('passwordField'),
                      c: _pw,
                      icon: CupertinoIcons.lock,
                      hint: '密码',
                      obscure: true,
                      onSubmitted: (_) => _submit()),
                  divider,
                  SizedBox(
                    height: Sizes.bar,
                    child: Row(children: [
                      const SizedBox(width: Gap.l),
                      SizedBox.square(dimension: Sizes.iconMd, child: Icon(CupertinoIcons.lock_shield, size: Sizes.iconMd - 2, color: pal.text2)),
                      const SizedBox(width: Gap.l),
                      Expanded(child: Text('记住密码', style: Theme.of(context).textTheme.bodyMedium)),
                      AppSwitch(
                        key: const Key('rememberPassword'),
                        value: _remember,
                        onChanged: (v) => setState(() => _remember = v),
                      ),
                      const SizedBox(width: Gap.s),
                    ]),
                  ),
                ]),
              ),
              AnimatedSize(
                duration: Motion.short4,
                child: _found.length > 1
                    ? Padding(
                        padding: const EdgeInsets.only(top: Gap.m),
                        child: Wrap(spacing: Gap.s, runSpacing: Gap.s, children: [
                          for (final s in _found)
                            OutlinedButton.icon(
                              style: OutlinedButton.styleFrom(fixedSize: const Size.fromHeight(Sizes.control), minimumSize: const Size(0, Sizes.control)),
                              icon: const Icon(CupertinoIcons.desktopcomputer, size: Sizes.iconSm),
                              label: Text('${s.name} (${s.address})', overflow: TextOverflow.ellipsis),
                              onPressed: () => setState(() => _server.text = s.address),
                            )
                        ]),
                      )
                    : const SizedBox.shrink(),
              ),
              MotionSwitch(
                child: _error == null
                    ? const SizedBox(height: Gap.xxl)
                    : Padding(
                        padding: const EdgeInsets.symmetric(vertical: Gap.m),
                        child: Text(_error!, key: const Key('loginError'), textAlign: TextAlign.center, style: tt.bodySmall?.copyWith(color: pal.danger)),
                      ),
              ),
              if (_pinMismatch)
                Padding(
                  padding: const EdgeInsets.only(bottom: Gap.s),
                  child: Text(
                    '指纹只用来认出是不是同一台服务器。它不管笔记在服务器硬盘上是不是密文。确定是你自己换过服务器，再点下面。',
                    textAlign: TextAlign.center,
                    style: tt.bodySmall?.copyWith(color: pal.text2),
                  ),
                ),
              if (widget.settings.knownServers.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: Gap.m),
                  child: Wrap(spacing: Gap.s, runSpacing: Gap.s, children: [
                    for (final s in widget.settings.knownServers)
                      InputChip(
                        label: Text(s, overflow: TextOverflow.ellipsis),
                        onPressed: () => setState(() => _server.text = s),
                        onDeleted: () => setState(() => widget.settings.forgetServer(s)),
                      ),
                  ]),
                ),
              if (_pinMismatch)
                Padding(
                  padding: const EdgeInsets.only(bottom: Gap.s),
                  child: FilledButton.tonal(
                    key: const Key('trustFingerprint'),
                    onPressed: _busy ? null : _trustNewPin,
                    style: FilledButton.styleFrom(fixedSize: const Size.fromHeight(Sizes.bar), minimumSize: const Size.fromHeight(Sizes.bar)),
                    child: const Text('改用新指纹并登录'),
                  ),
                ),
              FilledButton(
                key: const Key('loginButton'),
                onPressed: _busy ? null : _submit,
                style: FilledButton.styleFrom(fixedSize: const Size.fromHeight(Sizes.bar), minimumSize: const Size.fromHeight(Sizes.bar)),
                child: _busy
                    ? const SizedBox.square(dimension: Sizes.iconSm, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : Text(_registerMode ? '注册并登录' : '登录'),
              ),
              const SizedBox(height: Gap.s),
              Wrap(alignment: WrapAlignment.center, spacing: Gap.s, children: [
                TextButton(
                  onPressed: () => setState(() => _registerMode = !_registerMode),
                  child: Text(_registerMode ? '已有账号？去登录' : '没有账号？注册'),
                ),
                if (!_registerMode)
                  TextButton(key: const Key('forgotPasswordButton'), onPressed: _forgot, child: const Text('忘记密码？')),
              ]),
            ]),
          ),
        ),
      ),
    );
  }
}
