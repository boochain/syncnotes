import 'dart:async';

import 'package:syncnotes/ui/glass.dart';

/// 测试环境没有 GPU 着色器：玻璃退回 BackdropFilter，背景动画静止（pumpAndSettle 可结束）。
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  Glass.useShader = false;
  await testMain();
}
