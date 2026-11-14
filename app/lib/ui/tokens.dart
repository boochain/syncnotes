import 'package:flutter/material.dart';

/// 界面只使用这一套尺寸和颜色。业务页面不要再写另一套字号。
class Tokens {
  static const compact = 28.0;
  static const control = 32.0;
  static const input = 36.0;
  static const bar = 44.0;
  static const row = 56.0;
  static const sidebar = 260.0;
  static const list = 340.0;

  static const accent = Color(0xFF007AFF);
  static const accentDark = Color(0xFF0A84FF);

  static const lightBg = Color(0xFFFFFFFF);
  static const lightSide = Color(0xFFF5F5F7);
  static const lightFill = Color(0xFFF2F2F7);
  static const lightLine = Color(0xFFE5E5EA);
  static const lightText = Color(0xFF1D1D1F);
  static const lightText2 = Color(0xFF6E6E73);

  static const darkBg = Color(0xFF1C1C1E);
  static const darkSide = Color(0xFF232325);
  static const darkFill = Color(0xFF2C2C2E);
  static const darkLine = Color(0xFF38383A);
  static const darkText = Color(0xFFF5F5F7);
  static const darkText2 = Color(0xFFAEAEB2);
}
