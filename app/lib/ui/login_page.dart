import 'ds.dart';
import 'dart:io';
import 'tokens.dart';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../services/auth_api.dart';
import '../services/discovery.dart';
import '../services/settings.dart';

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
  bool _registerMode = false;
  bool _discovering = false;
  String? _error;
  List<DiscoveredServer> _found = [];

  Future<void> _submit() async {
    final server = _server.text.trim();
    if (server.isEmpty || _user.text.trim().isEmpty || _pw.text.isEmpty) {
      setState(() => _error = '请填写服务器地址、用户名和密码');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (_registerMode) {
        await widget.api.register(server, _user.text.trim(), _pw.text);
      }
      final r = await widget.api.login(
          server, _user.text.trim(), _pw.text, widget.settings.deviceId,
          deviceName: _deviceName());
      widget.settings
        ..server = server
        ..username = r.username
        ..token = r.token;
      widget.onLoggedIn();
    } catch (e) {
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
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
      backgroundColor: pal.bg,
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
                      hint: '服务器地址，如 192.168.1.10:7700',
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
              AnimatedSwitcher(
                duration: Motion.short4,
                child: _error == null
                    ? const SizedBox(height: Gap.xxl)
                    : Padding(
                        padding: const EdgeInsets.symmetric(vertical: Gap.m),
                        child: Text(_error!, key: const Key('loginError'), textAlign: TextAlign.center, style: tt.bodySmall?.copyWith(color: pal.danger)),
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
              TextButton(
                onPressed: () => setState(() => _registerMode = !_registerMode),
                child: Text(_registerMode ? '已有账号？去登录' : '没有账号？注册'),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}
