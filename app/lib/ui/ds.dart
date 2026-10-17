import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/cupertino.dart';
// SyncNotes v0.4 设计系统：一套调色板、一套字阶、一套高度、一套圆角、一套间距、一套图标。
//
// 不自创数值，全部取自成熟产品：
//   · 高度 / 间距 / 圆角 / 侧边栏尺寸：AppFlowy（开源 Flutter 版 Notion）设计令牌
//     —— HomeSizes.topBarHeight 44、HomeSpaceViewSizes.viewHeight 30 / leftPadding 16、
//        spacing 4/6/8/12/16/20、radius 4/6/8/12/16/20、文档图标 kIconHeight 60、正文 lineHeight 1.5
//        （只取数值，代码为独立实现；AppFlowy 为 AGPL，未复制任何源码）
//   · 颜色：Apple HIG 系统色（systemBlue 为唯一强调色，systemGray 系列为中性色）
//   · 编辑器排版与布局：Notion（内容宽 900、标题/正文比例、图标压住封面下沿）
// 说明见 docs/design-system.md。
import 'package:flutter/material.dart';

import 'tokens.dart';

/// 高度阶梯：同一行内的元素使用同一高度并垂直居中。
abstract final class Sizes {
  /// 行内小按钮、筛选标签、列表"更多"按钮
  static const compact = 28.0;

  /// 侧边栏行、菜单项、工具栏按钮、标题栏图标按钮、分段控件（AppFlowy viewHeight 30 → 32 对齐 4 点网格）
  static const control = 32.0;

  /// 输入框、发送栏（+ / 输入框 / 发送按钮同高）、主按钮、快速查找结果行
  static const input = 36.0;

  /// 标题栏、底部弹窗菜单行、登录表单行与主按钮（AppFlowy topBarHeight 44；HIG 最小点击区域 44）
  static const bar = 44.0;

  /// 两行列表项（收件箱行、斜杠菜单项、设置项）：统一固定高度
  static const listRow = 56.0;

  static const sidebarWidth = 260.0; // AppFlowy minimumSidebarWidth 268 附近，取 4 点网格
  static const iconSm = 16.0; // 行内、列表、菜单图标
  static const iconMd = 20.0; // 标题栏、工具栏图标；emoji 方框
  static const tile = 28.0; // 列表项左侧图标底

  static const all = [compact, control, input, bar, listRow];
}

/// 间距（AppFlowy spacing100–600 + 24/32）
abstract final class Gap {
  static const xs = 4.0, s = 6.0, m = 8.0, l = 12.0, xl = 16.0, xxl = 20.0, x3 = 24.0, x4 = 32.0;
}

/// 圆角（AppFlowy radius100–500）
abstract final class AppRadius {
  static const xs = 4.0; // 行内代码、复选框、徽标
  static const s = 6.0; // 侧边栏行、菜单项、标签、图标底
  static const m = 8.0; // 按钮、输入框、提示框、代码块、列表行悬停
  static const l = 12.0; // 浮层（菜单、快速查找、工具栏）、登录表单
  static const xl = 16.0; // 对话框、底部弹窗
}

/// 字阶：一个字体族，5 个字号，3 个字重（400 / 500 / 600）。所有"标题"统一 600。
abstract final class AppText {
  static const caption = TypeStyle(12, 16, FontWeight.w400); // 时间、说明、快捷键
  static const body = TypeStyle(14, 20, FontWeight.w400); // 界面正文（AppFlowy body 14/20）
  static const bodyStrong = TypeStyle(14, 20, FontWeight.w500); // 列表标题、选中项、按钮
  static const title = TypeStyle(16, 22, FontWeight.w600); // 标题栏、对话框、分组标题（AppFlowy heading4 16/22）
  static const headline = TypeStyle(20, 28, FontWeight.w600); // 空状态、登录页（AppFlowy heading3 20/28）
}

/// 中性调色板 + 唯一强调色（HIG systemBlue）。背景全部是纯色，不再使用彩色渐变。
@immutable
class AppColors extends ThemeExtension<AppColors> {
  final Color bg; // 内容区
  final Color sidebar; // 侧边栏 / 窄屏抽屉
  final Color elevated; // 浮层（菜单、对话框、快速查找、工具栏）
  final Color fill; // 输入框、提示框、代码块、图标底
  final Color hover; // 悬停叠加
  final Color selected; // 选中叠加（中性，不用强调色铺底）
  final Color separator;
  final Color text;
  final Color text2;
  final Color text3;
  final Color accent;
  final Color danger;
  final Color success;
  final Color warning;

  const AppColors({
    required this.bg,
    required this.sidebar,
    required this.elevated,
    required this.fill,
    required this.hover,
    required this.selected,
    required this.separator,
    required this.text,
    required this.text2,
    required this.text3,
    required this.accent,
    required this.danger,
    required this.success,
    required this.warning,
  });

  /// 浅色：白底 + Apple 浅灰侧边栏（#F5F5F7），HIG systemGray 系列中性色
  static const light = AppColors(
    bg: Color(0xFFFFFFFF),
    sidebar: Color(0xFFF5F5F7),
    elevated: Color(0xFFFFFFFF),
    fill: Color(0xFFF2F2F7), // systemGray6
    hover: Color(0x0A000000), // 4%
    selected: Color(0x12000000), // 7%
    separator: Color(0xFFE5E5EA), // systemGray5
    text: Color(0xFF1D1D1F),
    text2: Color(0xFF6E6E73),
    text3: Color(0xFF8E8E93), // systemGray（AA 大字 / 辅助信息）
    accent: Color(0xFF007AFF),
    danger: Color(0xFFFF3B30),
    success: Color(0xFF34C759),
    warning: Color(0xFFFF9500),
  );

  /// 深色：HIG 深色分层（#1C1C1E 内容 / #232325 侧边栏 / #2C2C2E 浮层与填充）
  static const dark = AppColors(
    bg: Color(0xFF1C1C1E),
    sidebar: Color(0xFF232325),
    elevated: Color(0xFF2C2C2E),
    fill: Color(0xFF2C2C2E),
    hover: Color(0x0FFFFFFF), // 6%
    selected: Color(0x1AFFFFFF), // 10%
    separator: Color(0xFF38383A),
    text: Color(0xFFF5F5F7),
    text2: Color(0xFFAEAEB2),
    text3: Color(0xFF8E8E93),
    accent: Color(0xFF0A84FF),
    danger: Color(0xFFFF453A),
    success: Color(0xFF30D158),
    warning: Color(0xFFFF9F0A),
  );

  static AppColors of(BuildContext context) =>
      Theme.of(context).extension<AppColors>() ?? (Theme.of(context).brightness == Brightness.dark ? dark : light);

  @override
  AppColors copyWith() => this;

  @override
  AppColors lerp(AppColors? other, double t) {
    if (other == null) return this;
    Color l(Color a, Color b) => Color.lerp(a, b, t)!;
    return AppColors(
      bg: l(bg, other.bg),
      sidebar: l(sidebar, other.sidebar),
      elevated: l(elevated, other.elevated),
      fill: l(fill, other.fill),
      hover: l(hover, other.hover),
      selected: l(selected, other.selected),
      separator: l(separator, other.separator),
      text: l(text, other.text),
      text2: l(text2, other.text2),
      text3: l(text3, other.text3),
      accent: l(accent, other.accent),
      danger: l(danger, other.danger),
      success: l(success, other.success),
      warning: l(warning, other.warning),
    );
  }
}

/// 页面封面：中性色调 + 强调色的浅色调，和界面同一色系（旧封面键名映射到这些色调）。
const coverTones = <String, (Color, Color)>{
  // key: (浅色, 深色)
  'gray': (Color(0xFFEDEDF0), Color(0xFF2C2C2E)),
  'blue': (Color(0xFFE3EDFB), Color(0xFF1F2933)),
  'slate': (Color(0xFFDDE2E8), Color(0xFF272B31)),
  'graphite': (Color(0xFFD1D1D6), Color(0xFF3A3A3C)),
};

const coverLabels = <String, String>{'gray': '浅灰', 'blue': '浅蓝', 'slate': '石板', 'graphite': '石墨'};

/// v0.2 / v0.3 的封面键名 → v0.4 色调
const legacyCoverMap = <String, String>{
  'sky': 'blue', 'ocean': 'blue', 'lavender': 'slate', 'night': 'graphite',
  'mint': 'gray', 'forest': 'slate', 'peach': 'gray', 'sunset': 'gray',
};

String? coverToneKey(Object? key) {
  if (key is! String || key.isEmpty) return null;
  if (coverTones.containsKey(key)) return key;
  return legacyCoverMap[key];
}

/// emoji 与文字对齐：固定方框 + 居中 + 行高 1.0、关闭字号缩放，避免 emoji 基线比中文低、尺寸忽大忽小。
class Emoji extends StatelessWidget {
  final String emoji;
  final double size; // 方框边长
  const Emoji(this.emoji, {super.key, required this.size});
  @override
  Widget build(BuildContext context) => SizedBox.square(
        dimension: size,
        child: Center(
          child: Text(
            emoji,
            textScaler: TextScaler.noScaling,
            maxLines: 1,
            overflow: TextOverflow.clip,
            style: TextStyle(fontSize: size * 0.8, height: 1.0, fontFamilyFallback: FontTokens.emojiFallback),
            strutStyle: StrutStyle(fontSize: size * 0.8, height: 1.0, forceStrutHeight: true),
          ),
        ),
      );
}

/// 弹出菜单项：统一高 32、图标 16、文字 14（AppFlowy 菜单行 / macOS 菜单）
PopupMenuItem<T> menuItem<T>(BuildContext context, T value, IconData icon, String label, {bool danger = false, Key? key}) {
  final c = AppColors.of(context);
  final color = danger ? c.danger : c.text;
  return PopupMenuItem<T>(
    key: key,
    value: value,
    height: Sizes.control,
    padding: const EdgeInsets.symmetric(horizontal: Gap.m),
    child: Row(children: [
      Icon(icon, size: Sizes.iconSm, color: danger ? c.danger : c.text2),
      const SizedBox(width: Gap.m),
      Flexible(
        child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: color)),
      ),
    ]),
  );
}

/// 危险操作确认对话框（删除等）：取消 = 文字按钮，确认 = 红色实心按钮，同为 36 高
Future<bool> confirmDanger(BuildContext context, {required String title, required String message, String confirm = '删除'}) async {
  final c = AppColors.of(context);
  final ok = await showDialog<bool>(
    context: context,
    builder: (d) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('取消')),
        FilledButton(
          key: const Key('confirmDanger'),
          style: FilledButton.styleFrom(backgroundColor: c.danger),
          onPressed: () => Navigator.pop(d, true),
          child: Text(confirm),
        ),
      ],
    ),
  );
  return ok == true;
}

/// HIG 开关（51×31）：开 = systemGreen
class AppSwitch extends StatelessWidget {
  final bool value;
  final ValueChanged<bool>? onChanged;
  const AppSwitch({super.key, required this.value, this.onChanged});
  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    return CupertinoSwitch(
      value: value,
      onChanged: onChanged,
      activeTrackColor: c.success,
      inactiveTrackColor: dark ? const Color(0x5C787880) : const Color(0x29787880),
    );
  }
}

/// HIG 分段控件：高 32，灰底 + 选中段为浮起的白色胶囊（iOS / macOS Segmented Control）。
/// 标题单行省略，窄宽度时隐藏图标；字号放大时只增高不溢出。
class SegmentedControl<T> extends StatelessWidget {
  final List<(T, IconData?, String)> segments;
  final T selected;
  final ValueChanged<T> onChanged;
  const SegmentedControl({super.key, required this.segments, required this.selected, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final tt = Theme.of(context).textTheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return LayoutBuilder(builder: (context, box) {
      final showIcons = box.maxWidth / segments.length >= 104;
      return Container(
        constraints: const BoxConstraints(minHeight: Sizes.control),
        padding: const EdgeInsets.all(2),
        decoration: BoxDecoration(color: c.fill, borderRadius: BorderRadius.circular(AppRadius.m)),
        child: IntrinsicHeight(
          child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            for (final (i, (value, icon, label)) in segments.indexed)
              Expanded(
                child: Semantics(
                  button: true,
                  selected: value == selected,
                  child: GestureDetector(
                    key: Key('seg-$i'),
                    behavior: HitTestBehavior.opaque,
                    onTap: () => onChanged(value),
                    child: AnimatedContainer(
                      duration: Motion.short4,
                      constraints: const BoxConstraints(minHeight: Sizes.compact),
                      padding: const EdgeInsets.symmetric(horizontal: Gap.s),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: value == selected ? (dark ? const Color(0xFF636366) : c.elevated) : Colors.transparent,
                        borderRadius: BorderRadius.circular(AppRadius.s),
                        boxShadow: value == selected && !dark
                            ? [BoxShadow(color: Colors.black.withValues(alpha: 0.12), blurRadius: 4, offset: const Offset(0, 1))]
                            : null,
                      ),
                      child: Row(mainAxisAlignment: MainAxisAlignment.center, mainAxisSize: MainAxisSize.min, children: [
                        if (icon != null && showIcons) ...[Icon(icon, size: Sizes.iconSm, color: c.text2), const SizedBox(width: Gap.s)],
                        Flexible(
                          child: Text(label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: (value == selected ? tt.labelLarge : tt.bodyMedium)?.copyWith(color: c.text)),
                        ),
                      ]),
                    ),
                  ),
                ),
              ),
          ]),
        ),
      );
    });
  }
}

/// 统一提示条：浮动、圆角 8；底部留出发送栏（36 + 上下 8 + 分隔线）的高度，不挡住输入框。
void showToast(BuildContext context, String message,
    {String? actionLabel, VoidCallback? onAction, ScaffoldMessengerState? messenger, Duration duration = const Duration(seconds: 4)}) {
  final m = messenger ?? ScaffoldMessenger.maybeOf(context);
  if (m == null) return;
  m.hideCurrentSnackBar();
  m.showSnackBar(SnackBar(
    content: Text(message, maxLines: 2, overflow: TextOverflow.ellipsis),
    margin: const EdgeInsets.fromLTRB(Gap.l, 0, Gap.l, Gap.l + Sizes.input + 2 * Gap.m + 1),
    duration: duration,
    // 带“撤销”按钮的提示条也会自动消失（Flutter 默认带操作的提示条常驻）
    persist: false,
    action: actionLabel == null ? null : SnackBarAction(label: actionLabel, onPressed: onAction ?? () {}),
  ));
}

/// 只有真正的鼠标才显示悬停态：触屏（含模拟器触摸、手写笔）上悬停高亮会"粘住"不消失。
bool isMouseHover(PointerEvent e) => e.kind == PointerDeviceKind.mouse;
