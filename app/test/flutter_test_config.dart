import 'dart:async';

import 'package:syncnotes/ui/glass.dart';

/// 测试关掉液态玻璃着色器，pumpAndSettle 可以结束。
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  Glass.useShader = false;
  Glass.enabled.value = false;
  await testMain();
}
