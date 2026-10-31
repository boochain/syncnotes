import 'package:flutter/material.dart';

import 'scope.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key, this.initialServer = ''});
  final String initialServer;

  @override
  State<LoginPage> createState() => LoginPageState();
}

class LoginPageState extends State<LoginPage> {
  late final TextEditingController _server = TextEditingController(text: widget.initialServer);
  final _user = TextEditingController();
  final _pass = TextEditingController();

  @override
  void dispose() {
    _server.dispose();
    _user.dispose();
    _pass.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = Scope.of(context);
    return Scaffold(
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: ListView(
              padding: const EdgeInsets.all(24),
              children: [
              const SizedBox(height: 48),
              Text('SyncNotes', style: Theme.of(context).textTheme.headlineMedium),
              const SizedBox(height: 8),
              Text('笔记在这台设备上加密，服务器只保存密文。', style: Theme.of(context).textTheme.bodyMedium),
              const SizedBox(height: 24),
              TextField(key: const Key('serverField'), controller: _server, decoration: const InputDecoration(labelText: '服务器')),
              const SizedBox(height: 12),
              TextField(key: const Key('userField'), controller: _user, decoration: const InputDecoration(labelText: '用户名')),
              const SizedBox(height: 12),
              TextField(key: const Key('passField'), controller: _pass, obscureText: true, decoration: const InputDecoration(labelText: '密码')),
              const SizedBox(height: 16),
              if (s.error != null) Text(s.error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
              const SizedBox(height: 8),
              FilledButton(
                key: const Key('loginButton'),
                onPressed: s.busy ? null : () => s.login(server: _server.text, username: _user.text, password: _pass.text, register: false),
                child: Text(s.busy ? '请稍候' : '登录'),
              ),
              const SizedBox(height: 8),
              OutlinedButton(
                key: const Key('registerButton'),
                onPressed: s.busy ? null : () => s.login(server: _server.text, username: _user.text, password: _pass.text, register: true),
                child: const Text('注册'),
              ),
              if (s.knownServers.isNotEmpty) ...[
                const SizedBox(height: 16),
                const Text('记住的服务器'),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  children: [
                    for (final host in s.knownServers)
                      InputChip(
                        label: Text(host),
                        onPressed: () => _server.text = host,
                        onDeleted: () => s.forgetServer(host),
                      ),
                  ],
                ),
              ],
            ],
            ),
          ),
        ),
      ),
    );
  }
}
