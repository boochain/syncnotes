import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'ds.dart';

/// 根页面“再按一次退出”：第一次返回显示提示，[window] 内再次返回才退出应用。
///
/// Android 规范：根页面按返回键直接退出容易误触，常见做法是双击退出。
/// 提示条复用 [showToast]（底部留出发送栏高度，不会挡住输入框）。
class BackToExit {
  BackToExit({this.window = const Duration(seconds: 2)});

  static const message = '再按一次退出';
  final Duration window;
  Timer? _armed;

  bool get armed => _armed?.isActive ?? false;

  /// 处理一次根页面返回；返回 true 表示已退出。
  bool handle(BuildContext context) {
    if (armed) {
      dispose();
      ScaffoldMessenger.maybeOf(context)?.hideCurrentSnackBar();
      SystemNavigator.pop();
      return true;
    }
    _armed = Timer(window, () => _armed = null);
    showToast(context, message, duration: window);
    return false;
  }

  void dispose() {
    _armed?.cancel();
    _armed = null;
  }
}

/// 根页面包装：拦截系统返回（含 Android 预测性返回），先交给 [onBack] 处理页面内状态，
/// [onBack] 返回 false（没有可以回退的内容）时执行“再按一次退出”。
class RootBackScope extends StatefulWidget {
  final Widget child;

  /// 先尝试回退页面内部状态（关闭抽屉、弹出嵌套路由……）。返回 true 表示已处理。
  final Future<bool> Function()? onBack;
  const RootBackScope({super.key, required this.child, this.onBack});

  @override
  State<RootBackScope> createState() => _RootBackScopeState();
}

class _RootBackScopeState extends State<RootBackScope> {
  final _exit = BackToExit();
  bool _busy = false;

  @override
  void dispose() {
    _exit.dispose();
    super.dispose();
  }

  Future<void> _onPop() async {
    if (_busy) return;
    _busy = true;
    try {
      final handled = await widget.onBack?.call() ?? false;
      if (!handled && mounted) _exit.handle(context);
    } finally {
      _busy = false;
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
        // 永远由 Flutter 处理返回：否则根 Navigator 只有一个路由时，系统会直接结束 Activity
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) _onPop();
        },
        child: widget.child,
      );
}
