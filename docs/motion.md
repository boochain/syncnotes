# SyncNotes 动效规范

本规范是笔记/页面进入退出、对话框与页内切换的**唯一套组**。不要再临时拼凑曲线或时长。

实现：`app/lib/ui/motion.dart`，token 在 `app/lib/ui/tokens.dart` 的 `Motion` / `MotionCurves`。

## 为何选这一套

对照了 Figma 官方与社区常用的 Smart Animate 节奏、[Apple HIG Motion](https://developer.apple.com/design/human-interface-guidelines/motion)、[Material 3 Easing and duration](https://m3.material.io/styles/motion/easing-and-duration/tokens-specs)、Fluent 2 的减速/加速曲线，以及 Notion、Linear、iOS `UINavigationController` 的转场做法。

| 来源 | 采用的部分 | 不直接整套搬来的原因 |
| --- | --- | --- |
| Material 3 Emphasized | 时长与缓动 token（进入 `emphasized-decelerate` + 400ms，可返回的退出用 `emphasized` + 300ms） | 单用 M3 Fade-through / Fade-forwards 会把两层正文做透明度交叉，正是叠字与闪一下的根因 |
| Apple HIG + iOS push | 空间让位：新页从尾侧滑入盖住旧页；旧页只做 30% 视差与压暗；**不对正文做透明度交叉**；动画可被手势/返回打断 | 纯 Cupertino 水平推页在 Windows 上不像本机，且与 Android 预测性返回的默认淡化不一致 |
| Fluent 2 | 进入用减速曲线、退出更快；用位移表达前进，而不是只用透明度 | 时长偏短（150–250ms），全屏页面会显得抢 |
| Linear / Notion | 路径短、不弹跳、不让两层字叠在一起 | 没有对外公布完整 token，不能当单一依据 |
| Figma Easy Ease / Smart Animate | 常见 300–400ms、尾部减速，与 M3 medium 段一致 | 社区文件曲线不统一，不适合当运行时规范 |
| 平台原生 builder | 仅在「减少动态效果」时退回无动画即时切换 | Android FadeForwards、iOS cupertino、Windows zoom 三者不一致；FadeForwards 仍用透明度，无法保证双端同一手感 |

结论：**时间轴用 Material 3 Emphasized token（仓库已有），空间层级用 iOS 式覆盖推入 + Fluent「不要只做透明度」**。这是一套完整套组，不是把几条曲线拼在一起。

## Token

一律使用已有常量，禁止在调用处写裸 `Duration(milliseconds: …)` 或 `Curves.easeOutCubic`。

| 角色 | Token | 值 |
| --- | --- | --- |
| 页面进入（走过大部分屏幕） | `Motion.medium4` + `MotionCurves.emphasizedDecelerate` | 400ms，`cubic-bezier(0.05, 0.7, 0.1, 1)` |
| 页面返回（临时退出，还可回来） | `Motion.medium2` + `MotionCurves.emphasized` | 300ms，`cubic-bezier(0.2, 0, 0, 1)` |
| 被盖住的下层视差/压暗 | 与当前转场同一时钟，曲线 `MotionCurves.emphasizedAccelerate` 用于压暗出现 | 视差位移最大 30% 屏宽 |
| 对话框 / 快速切换器 | `Motion.medium1` + 进入 `emphasizedDecelerate`、关闭 `emphasizedAccelerate` | 250ms，缩放 0.96→1，透明度仅用于浮层本身 |
| 页内切换（`MotionSwitch`） | `Motion.short4` + `emphasizedDecelerate` | 200ms；**只绘制当前子视图**，旧层立即卸下 |
| 微交互（芯片、按钮、悬停） | `Motion.short2`–`short3` + `MotionCurves.standard` | 100–150ms |

减少动态效果（`MediaQuery.disableAnimations`）时：所有页面转场时长视为 0，直接切到终态。

## 页面转场：空间与层级

用于笔记编辑器、页面、文件夹、设置、回收站、传输等通过 `fadeRoute` / 主题 `PageTransitionsBuilder` 推入的路由。

1. **新页（incoming）**
   - 从尾侧（`Offset(1, 0)` → `0`）整页滑入。
   - 全程不透明度 = 1（不对正文做淡入）。
   - 不做缩放。缩放会露出下层文字，并在结束时容易闪一下。
   - 用 `ClipRect` 裁切，滑动过程中文字不得画到路由边界外。
2. **旧页（outgoing，含根路由主页）**
   - 必须响应 `secondaryAnimation`（v0.7.1–0.7.2 的根因：根路由忽略了它，主页正文一直在）。
   - 向首侧视差平移最多 30% 屏宽（iOS push 惯例）。
   - 其上叠一层压暗（浅色最高约 16%，深色约 38%），不把旧页正文做成半透明交叉。
   - 旧页同样裁切。
3. **遮罩与材质**
   - 路由 `opaque: true`：动画结束后不再绘制被盖住的路由，省帧也防叠字。
   - 液态玻璃开启时，**不要**用主题 `surface` 实心 `ColoredBox` 包住子页（那会盖住 `GlassBackdrop` 流体背景）。可读性由页面自身的玻璃卡片/轻遮罩负责。
   - 关闭玻璃（含 `SYNCNOTES_GLASS=0` 与测试）时，子页用实心表面，保证正文对比度。
4. **禁止**
   - 两层正文同时以可阅读的不透明度叠在同一位置。
   - 在 `v >= 0.999` 时突然拆掉裁切、位移或压暗（这是「闪一下」的另一根因）。
   - 转场期间对全屏页面使用 `BackdropFilter` 或重阴影（掉帧）。

## 其它运动

- **`MotionSwitch`**：零叠层，只保留进入的子视图，避免宽屏收件箱/页面切换时叠字。
- **`MotionFade`**：仅用于对话框、菜单、快速切换器等浮层，允许透明度 + 微缩放。
- 弹簧（`Springs.smooth` / `snappy`）只用于菜单出现等手感反馈，不用于全屏转场，以免与 400ms 的 emphasized 套组抢性格。

## 无障碍

跟随系统「减少动态效果」。运动不是唯一信息通道（返回、关闭、状态都有静态界面）。
