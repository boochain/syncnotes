# SyncNotes 设计系统

SyncNotes 的视觉身份是 **Apple 风格 Liquid Glass**：鲜艳的流动渐变背景，上面叠加可折射、可模糊的玻璃面板。具体的字体、字阶、颜色、间距、圆角、阴影和动效数值**全部取自三套主流设计规范**，没有自创数值，并按平台做了适配：

| 缩写 | 规范 |
|---|---|
| **[HIG]** | Apple Human Interface Guidelines：Color、Typography（Dynamic Type）、Materials、Liquid Glass（iOS 26）、Motion |
| **[M3]** | Google Material Design 3：color roles / tonal palettes、type scale、shape、elevation、motion（easing & duration） |
| **[Fluent]** | Microsoft Fluent 2：color tokens、type ramp（Segoe UI Variable）、spacing ramp、corner radius、shadow、Mica / Acrylic、motion |

代码中的唯一来源是 [`app/lib/ui/tokens.dart`](../app/lib/ui/tokens.dart)，每个令牌旁都注明了出处。主题由 [`app/lib/ui/theme.dart`](../app/lib/ui/theme.dart) 根据令牌生成，玻璃材质实现见 [`app/lib/ui/glass.dart`](../app/lib/ui/glass.dart)。

## 1. 平台适配

| 平台 | 设计语言 | 字体 / 字阶 | 主色 | 圆角 | 动效曲线 | 玻璃 |
|---|---|---|---|---|---|---|
| Windows | Fluent 2 | Segoe UI Variable + Fluent type ramp | Fluent brand `#0F6CBD` | Fluent 4 / 8 / 12 | Fluent decelerateMid / accelerateMid | Liquid Glass，色调取 Acrylic 默认值 0.70 |
| Android | Material 3 | Roboto + M3 type scale | HIG systemBlue（M3 tonal palette 派生其余角色） | M3 shape 8 / 12 / 28 | M3 emphasized | Liquid Glass |
| Linux | Material 3 | Noto Sans + M3 type scale | HIG systemBlue | M3 shape | M3 emphasized | Liquid Glass |

所有平台都保留 Liquid Glass：脚手架透明，侧边栏、内容区、菜单、斜杠菜单、快速切换器都是玻璃面板。Android 前台服务的常驻通知由系统绘制，不受应用主题影响。

## 2. 颜色

### 2.1 系统色 [HIG]（浅色 / 深色）
| 令牌 | 浅色 | 深色 | 用途 |
|---|---|---|---|
| blue | `#007AFF` | `#0A84FF` | 主色（Android / Linux）、链接、选中 |
| green | `#34C759` | `#30D158` | 在线状态 |
| orange | `#FF9500` | `#FF9F0A` | 连接中、背景光斑 |
| red | `#FF3B30` | `#FF453A` | 错误、删除 |
| purple | `#AF52DE` | `#BF5AF2` | tertiary、背景光斑 |
| teal | `#30B0C7` | `#40C8E0` | secondary、背景光斑 |
| pink / indigo | `#FF2D55` / `#5856D6` | `#FF375F` / `#5E5CE6` | 背景光斑 |
| label | `#000000` | `#FFFFFF` | — |
| secondaryLabel | `#3C3C43` 60% | `#EBEBF5` 60% | onSurfaceVariant |
| separator | `#3C3C43` 29% | `#545458` 60% | outlineVariant |
| secondarySystemBackground | `#F2F2F7` | `#1C1C1E` | 深色玻璃底色 |

### 2.2 Fluent 令牌（Windows）[Fluent]
`colorBrandForeground1` `#0F6CBD` / `#479EF5`，`colorNeutralForeground1` `#242424` / `#FFFFFF`，`colorNeutralForeground2` `#424242` / `#D6D6D6`，`colorNeutralStroke2` `#E0E0E0` / `#525252`，`colorNeutralBackground1` `#FFFFFF` / `#292929`。

### 2.3 颜色角色 [M3]
`ColorScheme.fromSeed(tonalSpot)` 用主色生成 M3 色调调色板（tonal palette）和全部颜色角色（primaryContainer、surfaceContainer* 等），再用上面的 HIG 或 Fluent 语义色覆盖 primary、onSurface、outline、error 等角色。

### 2.4 可读性
- 内容面板（编辑器、列表）使用 *content* 玻璃，色调不透明度为浅色 0.74、深色 0.72，保证正文与面板的对比度 ≥ 4.5:1（WCAG AA）。`test/design_tokens_test.dart` 会验证这一点。
- 控件层（侧边栏、菜单）使用 *regular* 玻璃，浅色 0.45、深色 0.48，对应 HIG Liquid Glass 的 regular 变体。

## 3. 字体

### 3.1 字体族与 CJK 回退
- 西文：Windows 用 `Segoe UI Variable Text` [Fluent]；Apple 平台用 SF Pro（`.AppleSystemUIFont`）[HIG]；Android 用 `Roboto` [M3]；Linux 用 `Noto Sans`。
- 中文回退链：`Microsoft YaHei UI` → `PingFang SC` → **`HarmonyOS Sans SC`** → **`MiSans`** → **`Noto Sans CJK SC` / `Noto Sans SC` / `Source Han Sans SC`（思源黑体）** → `WenQuanYi Micro Hei`。加粗的几款均可免费使用（Noto / 思源为 SIL OFL；HarmonyOS Sans 与 MiSans 可免费商用）。安装包没有内置字体，以保持体积；如需统一字形，可把 Noto Sans SC 放进 `assets/fonts` 并在 pubspec 中声明。
- 等宽：`JetBrains Mono` → `Cascadia Code` → `SF Mono` → `Menlo` → `Consolas` → `Noto Sans Mono CJK SC`。

### 3.2 字阶
**[M3] type scale**（Android / Linux 的 UI 文字），格式为 字号 / 行高 / 字重：
displayLarge 57/64/400 · displayMedium 45/52 · displaySmall 36/44 · headlineLarge 32/40 · headlineMedium 28/36 · headlineSmall 24/32 · titleLarge 22/28/400 · titleMedium 16/24/500 · titleSmall 14/20/500 · bodyLarge 16/24 · bodyMedium 14/20 · bodySmall 12/16 · labelLarge 14/20/500 · labelMedium 12/16/500 · labelSmall 11/16/500

**[Fluent] type ramp**（Windows 的 UI 文字）：
caption2 10/14 · caption1 12/16 · body1 14/20 · body1Strong 14/20/600 · subtitle2 16/22/600 · subtitle1 20/28/600 · title3 24/32/600 · title2 28/36/600 · title1 32/40/600 · largeTitle 40/52/600 · display 68/92/600

**[HIG] Dynamic Type "Large"**（编辑器标题层级，所有平台一致）：
页面标题 = largeTitle 34/41（加粗）· H1 = title1 28/34 · H2 = title2 22/28 · H3 = title3 20/25 · callout 16/21（引用 / 提示块）。正文取 [M3] bodyLarge 的 16，但行高放宽到 26（1.6 倍），更适合中文阅读。代码块为 14/21。

## 4. 间距：4 点网格
[M3] 4dp baseline grid 与 [Fluent] spacing ramp 一致：`xxs 2 · xs 4 · s 8 · m 12 · l 16 · xl 20 · xxl 24 · xxxl 32`。编辑器左右留白为 48。

## 5. 圆角
| 令牌 | 值 | 来源 | 用途 |
|---|---|---|---|
| extraSmall | 4 | M3 | 工具提示 |
| small | 8 | M3 | 控件（Android / Linux）、标签 |
| medium | 12 | M3 | 卡片、菜单 |
| large | 16 | M3 | — |
| extraLarge | 28 | M3 | 对话框、底部弹出层 |
| fluentMedium | 4 | Fluent | 控件（Windows） |
| fluentLarge | 8 | Fluent | 卡片（Windows） |
| fluentXLarge | 12 | Fluent | 对话框（Windows） |
| glassPanel | 22 | HIG（连续曲线 superellipse，与外框同心） | 侧边栏、内容区、快速切换器 |

M3 的按钮是全圆角胶囊；Windows 上按钮使用 Fluent 的 4px 圆角。

## 6. 阴影 / 层级
- [M3] elevation：level0–5 = 0 / 1 / 3 / 6 / 8 / 12 dp。弹出菜单在 Android / Linux 上用 level2，在 Windows 上用 level4。
- [Fluent] shadow16：`0 0 2px rgba(0,0,0,.12), 0 8px 16px rgba(0,0,0,.14)`（`Elevation.fluentShadow16`）。
- 玻璃面板主要靠折射、高光和边缘光（liquid_glass_widgets 的 specular / fresnel）来表现层次，不依赖投影。

## 7. 材质
- **Liquid Glass [HIG]**：用开源库 [`liquid_glass_widgets`](https://pub.dev/packages/liquid_glass_widgets) 的 `GlassContainer` 实现。它用自定义片元着色器完成实时模糊、折射、高光和色散，支持 Windows、Linux、Android、macOS、iOS 和 Web。各变体的参数：
  - regular：blur 12，色调 0.45 / 0.48，saturation 1.7；
  - content：blur 18，色调 0.74 / 0.72。
- **Acrylic [Fluent]**（Windows）：regular 玻璃的色调提高到 Acrylic 默认值 0.70，blur 为 σ15（对应 Acrylic 30px）。
- **背景**：缓慢流动的渐变光斑，40 秒一圈，颜色取 HIG 系统色。玻璃需要背后有内容才能看出折射效果。系统开启"减少动态效果"时背景静止。
- **回退方案**：环境变量 `SYNCNOTES_GLASS=0`（旧显卡、远程桌面、虚拟机）和 widget 测试环境会改用 `BackdropFilter` 加半透明色调层的毛玻璃。

## 8. 动效
- **时长 [M3]**：short1–4 = 50 / 100 / 150 / 200 ms；medium1–4 = 250 / 300 / 350 / 400 ms；long1–2 = 450 / 500 ms。代码中统一用 `Motion.*`。悬停反馈用 short3，面板切换用 medium1–2，页面路由用 medium2。
- **[Fluent] 时长**：fast 150、normal 200、gentle 250。
- **缓动 [M3]**：emphasized `(0.2,0,0,1)`、emphasizedDecelerate `(0.05,0.7,0.1,1)`、emphasizedAccelerate `(0.3,0,0.8,0.15)`、standard `(0.2,0,0,1)`。
- **缓动 [Fluent]**：decelerateMid `(0,0,0,1)`、accelerateMid `(1,0,1,1)`、easyEase `(0.33,0,0.67,1)`。`MotionCurves.enter` / `exit` 会按平台自动选用。
- **弹簧 [HIG]**：取 SwiftUI 的弹簧参数，按 stiffness = (2π/response)²、damping = 4π·ζ/response 换算（mass = 1）：
  - smooth：spring(response 0.55, ζ 0.825)，即 stiffness ≈ 130.5；
  - bouncy：(0.5, 0.7)，用于斜杠菜单和快速切换器出现时的回弹；
  - snappy：(0.4, 0.85)。
- 玻璃控件的按压形变、果冻弹性由 liquid_glass_widgets 的物理引擎提供。

## 9. 组件对照
| 组件 | 材质 | 圆角 | 字阶 | 动效 |
|---|---|---|---|---|
| 托盘小窗 | 全屏 content 玻璃叠在渐变上 | — | M3 / Fluent | — |
| 侧边栏 | regular 玻璃（窄屏时为抽屉） | glassPanel 22 | labelLarge / bodyMedium | short3 悬停，medium1 展开 |
| 编辑器内容区 | content 玻璃 | glassPanel 22 | HIG 标题层级 + 正文 16/26 | medium1 切页（emphasized） |
| 斜杠菜单 | content 玻璃 | 16 | bodyMedium | bouncy 弹簧 |
| 快速切换器（Ctrl+K） | content 玻璃 | glassPanel 22 | bodyMedium | bouncy 弹簧 + medium4 |
| 卡片（收件箱） | 半透明表面 + 白色描边 | card（M3 12 / Fluent 8） | titleSmall / bodyMedium | short4 + stagger |
| 菜单 / 对话框 / 底部弹出层 | 半透明表面（0.88–0.90） | card / dialog / extraLarge | — | 系统默认 |
