import 'dart:async';

import 'package:syncnotes/ui/glass.dart';

/// 测试关掉玻璃阴影，页面动画不再采样背景，pumpAndSettle 可以结束。
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  Glass.useShader = false;
  Glass.enabled.value = false;
  await testMain();
}
