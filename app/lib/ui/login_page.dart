import 'dart:io';
import 'tokens.dart';

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

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 380),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Icon(Icons.sync_alt_rounded, size: 56, color: cs.primary),
              const SizedBox(height: 8),
              Text('SyncNotes',
                  textAlign: TextAlign.center, style: Theme.of(context).textTheme.headlineMedium),
              Text('多设备实时同步的笔记与消息',
                  textAlign: TextAlign.center, style: TextStyle(color: cs.outline)),
              const SizedBox(height: 24),
              TextField(
                key: const Key('serverField'),
                controller: _server,
                decoration: InputDecoration(
                  labelText: '服务器地址',
                  hintText: '例如 192.168.1.10:7700 或 https://notes.example.com',
                  prefixIcon: const Icon(Icons.dns_outlined),
                  border: const OutlineInputBorder(),
                  suffixIcon: _discovering
                      ? const Padding(
                          padding: EdgeInsets.all(12),
                          child: SizedBox(
                              width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)))
                      : IconButton(
                          tooltip: '搜索局域网服务器',
                          icon: const Icon(Icons.wifi_find),
                          onPressed: _discover),
                ),
              ),
              AnimatedSize(
                duration: Motion.short4,
                child: _found.length > 1
                    ? Wrap(spacing: 8, children: [
                        for (final s in _found)
                          ActionChip(
                            avatar: const Icon(Icons.lan, size: 16),
                            label: Text('${s.name} (${s.address})'),
                            onPressed: () => setState(() => _server.text = s.address),
                          )
                      ])
                    : const SizedBox.shrink(),
              ),
              const SizedBox(height: 12),
              TextField(
                key: const Key('userField'),
                controller: _user,
                decoration: const InputDecoration(
                    labelText: '用户名', prefixIcon: Icon(Icons.person_outline), border: OutlineInputBorder()),
              ),
              const SizedBox(height: 12),
              TextField(
                key: const Key('passwordField'),
                controller: _pw,
                obscureText: true,
                onSubmitted: (_) => _submit(),
                decoration: const InputDecoration(
                    labelText: '密码', prefixIcon: Icon(Icons.lock_outline), border: OutlineInputBorder()),
              ),
              AnimatedSwitcher(
                duration: Motion.short4,
                child: _error == null
                    ? const SizedBox(height: 16)
                    : Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Text(_error!, style: TextStyle(color: cs.error)),
                      ),
              ),
              FilledButton(
                key: const Key('loginButton'),
                onPressed: _busy ? null : _submit,
                style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 16)),
                child: _busy
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : Text(_registerMode ? '注册并登录' : '登录'),
              ),
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
