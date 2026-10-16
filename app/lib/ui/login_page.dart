import 'glass.dart';
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

  /// HIG 分组输入行：无边框、无填充，图标 + 输入框，多行之间用细分隔线（iOS 登录表单样式）
  Widget _row(BuildContext context, {required Key key, required TextEditingController c, required IconData icon,
      required String hint, bool obscure = false, Widget? suffix, ValueChanged<String>? onSubmitted, String? label}) {
    final cs = Theme.of(context).colorScheme;
    return SizedBox(
      height: 48,
      child: Row(children: [
        const SizedBox(width: 14),
        Icon(icon, size: 19, color: cs.onSurfaceVariant),
        const SizedBox(width: 12),
        Expanded(
          child: TextField(
            key: key,
            controller: c,
            obscureText: obscure,
            onSubmitted: onSubmitted,
            style: const TextStyle(fontSize: 15),
            decoration: InputDecoration.collapsed(hintText: hint).copyWith(filled: false, semanticCounterText: label),
          ),
        ),
        ?suffix,
        const SizedBox(width: 6),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final divider = Divider(height: 0.5, thickness: 0.5, indent: 45, color: cs.outlineVariant.withValues(alpha: 0.6));
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              // 应用图标：HIG 圆角方形 + 柔和渐变 + SF Symbols 风格图形
              Center(
                child: Container(
                  width: 64,
                  height: 64,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(15),
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: dark ? const [Color(0xFF0A84FF), Color(0xFF5E5CE6)] : const [Color(0xFF34AADC), Color(0xFF007AFF)],
                    ),
                    boxShadow: [BoxShadow(color: const Color(0xFF007AFF).withValues(alpha: 0.25), blurRadius: 18, offset: const Offset(0, 6))],
                  ),
                  child: const Icon(CupertinoIcons.arrow_2_squarepath, color: Colors.white, size: 32),
                ),
              ),
              const SizedBox(height: 16),
              Text('SyncNotes',
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w700, letterSpacing: 0.3)),
              const SizedBox(height: 4),
              Text('多设备实时同步的笔记与消息', textAlign: TextAlign.center, style: TextStyle(fontSize: 14, color: cs.onSurfaceVariant)),
              const SizedBox(height: 28),
              Glass(
                radius: Radii.card,
                strong: true,
                child: Column(children: [
                  _row(context,
                      key: const Key('serverField'),
                      c: _server,
                      icon: CupertinoIcons.globe,
                      hint: '服务器地址，如 192.168.1.10:7700',
                      label: '服务器地址',
                      suffix: _discovering
                          ? const Padding(
                              padding: EdgeInsets.all(12),
                              child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)))
                          : IconButton(
                              tooltip: '搜索局域网服务器',
                              icon: Icon(CupertinoIcons.wifi, size: 19, color: cs.primary),
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
                        padding: const EdgeInsets.only(top: 10),
                        child: Wrap(spacing: 8, runSpacing: 8, children: [
                          for (final s in _found)
                            ActionChip(
                              avatar: const Icon(CupertinoIcons.desktopcomputer, size: 16),
                              label: Text('${s.name} (${s.address})'),
                              onPressed: () => setState(() => _server.text = s.address),
                            )
                        ]),
                      )
                    : const SizedBox.shrink(),
              ),
              AnimatedSwitcher(
                duration: Motion.short4,
                child: _error == null
                    ? const SizedBox(height: 20)
                    : Padding(
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        child: Text(_error!, textAlign: TextAlign.center, style: TextStyle(color: cs.error, fontSize: 13)),
                      ),
              ),
              FilledButton(
                key: const Key('loginButton'),
                onPressed: _busy ? null : _submit,
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(46),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.card)),
                  textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                ),
                child: _busy
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : Text(_registerMode ? '注册并登录' : '登录'),
              ),
              const SizedBox(height: 6),
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
