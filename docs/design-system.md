# SyncNotes 设计系统（v0.3）

v0.3 重做了界面，原则如下：

1. **Apple HIG 是基础**：颜色、字号层级、材质、间距、圆角、图标、动效都以 HIG 为准，**所有平台统一**（Windows、Linux、Android 不再各自换成 Fluent / Material 外观）。
2. **布局和交互照 Notion**：侧边栏、封面 + 压住封面下沿的图标、标题、块排版、悬停手柄、斜杠菜单、快速查找、行内格式工具栏。
3. **只在明显更好的地方借用 Material 3 / Fluent 2**，每一处都在下文「混用」一节写明来源和理由。

令牌在 `app/lib/ui/tokens.dart`，主题在 `app/lib/ui/theme.dart`，玻璃材质在 `app/lib/ui/glass.dart`。

---

## 1. 颜色（HIG 系统色）

| 令牌 | 浅色 | 深色 | 用途 |
|---|---|---|---|
| `HigColors.blue` | #007AFF | #0A84FF | 主色：选中项、链接、主按钮、光标 |
| `HigColors.green` | #34C759 | #30D158 | 开关开启、"在线"状态 |
| `HigColors.orange` | #FF9500 | #FF9F0A | 连接中、文件夹图标底 |
| `HigColors.red` | #FF3B30 | #FF453A | 删除、退出登录、错误 |
| `HigColors.purple / indigo / teal / pink` | 系统色 | 系统色 | 背景光斑、块类型图标底 |
| 正文 | #1D1D1F | #F5F5F7 | Apple 官网正文色，比纯黑 / 纯白柔和 |
| `secondaryLabel` | #3C3C43 60% | #EBEBF5 60% | 次要文字、时间 |
| `separator` | #3C3C43 29% | #545458 60% | 分隔线 |
| systemFill（开关关闭轨道） | #787880 20% | #787880 36% | 关闭状态的开关 |

编辑器内容色照 Notion：
- 提示框（callout）底：浅色 #37352F 5%（≈ Notion #F1F1EF），深色 白 6%
- 行内代码：文字 #EB5757（深色 #FF7B72），底 #878378 15%，等宽字体
- 封面预设（`coverPresets`）全部是低饱和双色渐变（sky / ocean / mint / forest / peach / sunset / lavender / night），深色模式下再压暗 28%，不会出现刺眼的大面积亮色

## 2. 字体与字号

- 西文：系统 UI 字体（SF Pro / Segoe UI Variable / Roboto，平台自带，不打包）
- 中文回退链（免费字体优先）：Microsoft YaHei UI → PingFang SC → HarmonyOS Sans SC → MiSans → Noto Sans CJK SC → Source Han Sans SC → WenQuanYi Micro Hei
- 等宽：JetBrains Mono → Cascadia Code → SF Mono → Menlo → Consolas → Noto Sans Mono CJK SC

**界面字号**用 HIG 的 Dynamic Type 层级：触屏用 `HigType`（Large，正文 17），桌面用 `HigTypeSmall`（macOS 尺寸，正文 15）。

**编辑器字号**用 Notion 的比例（`EditorType`）：

| 元素 | 字号 / 行高 | 字重 |
|---|---|---|
| 页面标题 | 40 / 48（窄屏 32） | 700 |
| 一级标题 | 30 / 39 | 600 |
| 二级标题 | 24 / 31 | 600 |
| 三级标题 | 20 / 26 | 600 |
| 正文、引用 | 16 / 26 | 400 |
| 代码 | 14 / 21 | 400 |

中文没有斜体字形，合成倾斜会和相邻字挤在一起、看起来像删除线。所以**中文的 `*强调*` 用点状下划线**（着重号的变体，符合 GB/T 15834 的着重习惯），西文仍用斜体。

## 3. 布局（Notion）

| 项 | 值 |
|---|---|
| 内容最大宽度 | 900（`EditorType.maxWidth`） |
| 左右留白 | 宽屏 56，窄屏 28 |
| 块手柄栏 | 宽屏 44（"+" 与 "⠿"），窄屏 24（只留拖动手柄） |
| 封面高度 | 宽屏 200，窄屏 150 |
| 页面图标 | 78（窄屏 64），**45% 压在封面下沿**，画在封面之上，左边和标题对齐；图标下方到标题留 14 |
| 侧边栏 | 收件箱 / 搜索 / 设置 + 页面树；选中项用主色 12% 底 + 主色文字（HIG 侧边栏样式） |
| 宽窄断点 | ≥ 720 显示侧边栏，小于 720 用抽屉（托盘小窗、手机） |
| 设置页 | 内容限宽 680 并居中（HIG 设置页），避免宽屏下开关离标签太远 |

封面和图标的几何关系由 `test/design_layout_test.dart` 守护（宽屏和 390px 两种尺寸：图标跨过封面下沿、覆盖比例 30%–60%、完整可见、在 Stack 最上层、和标题不重叠且左对齐），另有一张金样图 `test/goldens/page_head_wide.png`。

## 4. 间距与圆角

间距是 4 的倍数：2 / 4 / 8 / 12 / 16 / 20 / 24 / 32 / 48（`Space`）。

| 圆角令牌 | 值 | 用途 |
|---|---|---|
| `Radii.control` | 8 | 按钮、输入框、菜单项、侧边栏项 |
| `Radii.card` | 12 | 卡片、登录表单组、浮动工具栏 |
| `Radii.dialog` | 14 | 对话框、快速查找 |
| `Radii.glassPanel` | 22 | 大玻璃面板（侧边栏、内容区） |

## 5. 材质（Liquid Glass）

- 使用开源库 [liquid_glass_widgets](https://pub.dev/packages/liquid_glass_widgets) 1.13（着色器折射 + 模糊 + 边缘高光），支持 Windows / Linux / Android。没有选 `liquid_glass_renderer`，因为它只支持 Apple 平台和 Android，而且很久没更新。
- 面板分两档：普通（侧边栏、内容区）和 `strong`（弹出菜单、工具栏、登录表单，透明度更低以保证文字可读）。
- 背景是缓慢流动的 HIG 系统色光斑（`GlassBackdrop`）。
- `SYNCNOTES_GLASS=0` 时改用 `BackdropFilter` 毛玻璃，适合旧显卡和远程桌面。`adaptiveQuality` 保持关闭（在软件渲染下调整窗口会崩溃）。

## 6. 图标

全部使用 SF Symbols 风格的 `CupertinoIcons`（细线条、圆角端点），固定 `cupertino_icons ^1.0.9`（2.0 改成了 cupertino_ui，字体缺字会显示方块）。
- 斜杠菜单中的标题命令显示 "H1 / H2 / H3" 字形，而不是三个相同图标（照 Notion）
- 收件箱条目：30px 圆角方形图标底，页面显示自己的 emoji

## 7. 动效

- 弹簧：用 HIG 的 response / damping 参数换算成刚度（`Springs`，`SpringCurve`），用于面板展开、图标弹出
- 时长令牌沿用 Material 3 的 short / medium / long 阶梯（`Motion`），见下节
- 页面切换：Cupertino 横滑；Android 保留预测性返回

---

## 8. 混用了哪些 Material 3 / Fluent 2，为什么

| 来源 | 用在哪 | 为什么比纯 HIG 更好 |
|---|---|---|
| **Material 3** 色调调色板 | 由 systemBlue 生成中性色阶（surfaceContainer 系列）填补 HIG 没定义的层级 | HIG 只给了 3 层背景色，玻璃上的卡片、悬停、按下态需要更多稳定的中间层 |
| **Material 3** 时长与缓动令牌 | 非弹簧的淡入淡出、尺寸变化 | HIG 没有公开的时长表；M3 的阶梯完整且和弹簧不冲突 |
| **Material 3** 预测性返回 | Android 页面返回 | 这是 Android 14+ 的系统手势，用 Cupertino 横滑会和系统冲突 |
| **Material 3** 状态层 | 悬停 5%、选中 12% 的叠加透明度 | 统一的数值让侧边栏、列表、菜单的悬停/选中一致 |
| **Fluent 2** 间距阶梯 | `Space`（2–32） | Fluent 的阶梯是 4 的倍数并且命名清楚，HIG 没有官方间距表 |
| **Fluent 2** 键盘与焦点习惯 | 桌面端快捷键提示（如侧边栏"搜索 Ctrl+K"）、快速查找底部的 "↑↓ 选择 ↵ 打开" | Windows 用户依赖键盘；Fluent 把快捷键直接显示在入口上，比 HIG 只放在菜单里更好发现 |
| **Fluent 2** Acrylic 参数 | 关闭着色器时的毛玻璃回退（`Materials.acrylicTint` / `blurAcrylic`） | 在 Windows 上更接近系统原生的亚克力观感，性能也更稳定 |

没有采用的：Material 的悬浮操作按钮（FAB）、水波纹（主题里关闭了 splash）、Fluent 的 2px 小圆角。它们和 HIG 的视觉语言冲突。

## 9. 视觉验收流程

每次改界面都要：重新构建 → 在 Xvfb 上截图（移动鼠标并等待再截，避免拿到旧帧）→ 逐张查看 → 对照 Notion / Apple 挑问题 → 修改 → 重复。范围包括托盘小窗、收件箱、编辑器、斜杠菜单、快速查找、设置、登录、抽屉，每个都看浅色 / 深色、窄（约 390px）/ 宽。v0.3 的最终截图在 `docs/screenshots/v0.3-*.png`。
