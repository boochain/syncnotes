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
  var _showPassword = false;

  void _submit(bool register) {
    final s = Scope.of(context);
    if (_server.text.trim().isEmpty || _user.text.trim().isEmpty || _pass.text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('服务器、用户名和密码都要填')));
      return;
    }
    if (register && _pass.text.length < 8) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('密码至少 8 位。这是解开笔记的钥匙，丢了找不回来。')));
      return;
    }
    s.login(server: _server.text, username: _user.text, password: _pass.text, register: register);
  }

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
              Text('笔记在这台设备上加密。密码就是钥匙，服务器帮你保管不了。', style: Theme.of(context).textTheme.bodyMedium),
              const SizedBox(height: 24),
              TextField(key: const Key('serverField'), controller: _server, decoration: const InputDecoration(labelText: '服务器')),
              const SizedBox(height: 12),
              TextField(key: const Key('userField'), controller: _user, decoration: const InputDecoration(labelText: '用户名')),
              const SizedBox(height: 12),
              TextField(
                key: const Key('passField'),
                controller: _pass,
                obscureText: !_showPassword,
                decoration: InputDecoration(
                  labelText: '密码',
                  suffixIcon: IconButton(
                    tooltip: _showPassword ? '隐藏密码' : '显示密码',
                    onPressed: () => setState(() => _showPassword = !_showPassword),
                    icon: Icon(_showPassword ? Icons.visibility_off : Icons.visibility),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              if (s.error != null) Text(s.error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
              const SizedBox(height: 8),
              FilledButton(
                key: const Key('loginButton'),
                onPressed: s.busy ? null : () => _submit(false),
                child: Text(s.busy ? '请稍候' : '登录'),
              ),
              const SizedBox(height: 8),
              OutlinedButton(
                key: const Key('registerButton'),
                onPressed: s.busy ? null : () => _submit(true),
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
