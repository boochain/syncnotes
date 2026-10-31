import 'package:flutter/material.dart';

import 'scope.dart';

class LockPage extends StatefulWidget {
  const LockPage({super.key});

  @override
  State<LockPage> createState() => LockPageState();
}

class LockPageState extends State<LockPage> {
  final _pin = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _pin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = Scope.of(context);
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.lock_outline, size: 40),
              const SizedBox(height: 12),
              const Text('先输入应用锁，再看笔记'),
              const SizedBox(height: 12),
              TextField(
                controller: _pin,
                obscureText: true,
                autofocus: true,
                decoration: const InputDecoration(labelText: '应用锁'),
                onSubmitted: (_) => _go(s),
              ),
              if (_error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error))),
              const SizedBox(height: 12),
              FilledButton(onPressed: () => _go(s), child: const Text('打开')),
            ]),
          ),
        ),
      ),
    );
  }

  void _go(dynamic s) {
    if (s.tryUnlock(_pin.text)) return;
    setState(() => _error = '不对');
  }
}
