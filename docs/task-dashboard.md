# 任务仪表盘设计

随 SyncNotes v0.8.0 发布。不改协议大版本。日历会把带日期的任务只读叠加显示（见 docs/calendar.md），网页版可查看任务并勾选完成（见 docs/web-client.md）。

侧边栏增加「任务」入口，打开独立仪表盘。不改收件箱顶栏布局（其他分支正在改动画 / 顶栏 / 玻璃）。Android 返回键约定保持不变：仪表盘与任务详情走内容区嵌套 Navigator，返回先退出详情，再退出仪表盘，回到根页面后仍需按两次退出。

## 1. 调研：主流产品怎么做任务进度

对比了 Todoist、Things、TickTick / 滴答、Linear、Asana、Notion、ClickUp、Microsoft To Do、Apple Reminders，以及用户明确点名的能力（任务项、重要程度、起止时间、完成时间、自定义进度组成与权重、子任务起止时间）。

### 用户已要求的部分（必须做）

| 能力 | 常见做法 | SyncNotes 采用 |
| --- | --- | --- |
| 任务项 | 所有产品都以任务为基本单位 | 新块类型 `task`，可出现在收件箱根目录或文件夹中 |
| 重要程度 | Todoist / 滴答四级优先级（紧急 / 高 / 中 / 低）；Things 更克制 | 四级 +「无」：紧急 / 高 / 中 / 低 / 无，颜色只用系统红 / 橙 / 蓝 / 灰 |
| 起止时间 | Things 把 When（计划开始）和 Deadline（必须完成）分开；Todoist 也区分 date 与 deadline | `start_at` + `due_at`，可只填日期（全天）或带时刻 |
| 完成时间 | Microsoft Project / Planner 记录实际完成；多数待办只记勾选瞬间 | `completed_at`：勾选时自动写入，允许事后改正 |
| 自定义进度组成与权重 | 用户强烈需要，但多数产品只按「完成条数 / 总条数」。TaskRay Custom、Asana 自定义字段 workaround、Notion 公式、ClickUp 多次被求但未做好 | 每个任务可自定义进度项：标题、权重、类型（勾选 / 百分比 / 关联子任务），进度 = Σ(完成比例 × 权重) / Σ(权重) |
| 子任务起止时间 | 滴答子任务与父任务字段对等，最多 5 层 | 子任务也是 `task` 块，同样有起止 / 完成时间、优先级和自己的进度；最多 5 层 |

### 用户没点名、但值得融入的设计

1. **仪表盘总览，而不是只有一份列表**（Todoist Insights、Asana Dashboard、Linear 项目图）  
   顶部卡片：逾期、今天、进行中、有风险、本周已完成，以及整体完成比例。进度变化应如实反映范围变化：新增进度项或子任务后，百分比可能下降（Todoist / Linear 都明确这一点）。

2. **智能列表**（Things Today / Upcoming / Logbook，Microsoft To Do 的 My Day，Apple Reminders 的今天 / 已计划 / 旗标）  
   - **今天**：今天到期、已开始且未结束、标了旗标，以及逾期（Things 把逾期放进今天，避免漏掉）  
   - **即将**：未来 7 天到期（不含今天）  
   - **逾期 / 进行中 / 有风险 / 全部未完成 / 已完成（日志） / 里程碑**

3. **健康状态，自动算，不用手动填「项目状态」**（Todoist Health / At risk，Asana On track / At risk / Off track）  
   - 已完成 / 已取消 / 逾期 / 有风险 / 进度正常 / 未开始 / 进行中  
   - **有风险**：已逾期，或距截止不足 48 小时且进度不足 70%，或按起止时间线性预估落后 25% 以上，或已过开始时间、截止在 7 天内、进度仍为 0

4. **三种进度模式**（滴答可手拖百分比；多数产品按条数；加权是强烈需求）  
   - **加权**（默认）：按用户设定的权重  
   - **均分**：每项 / 每个子任务同等权重  
   - **手动**：直接指定 0–100%（适合难以拆分的工作）

5. **父任务进度由子项汇总，且支持部分完成**（ClickUp / Notion 用户反复要求：不要只把子任务当成 0 或 100）  
   子任务自己的进度（加权 / 均分 / 手动 / 已完成）按权重滚入父任务。已取消的子任务不计入分母（类似 Linear 取消的 issue 从范围里拿掉）。

6. **全部完成后自动完成父任务**（Linear parent auto-close，滴答检查项全部完成则父任务完成）  
   默认开启，可在任务里关掉。反向级联（父任务完成则勾掉所有子任务）默认关闭，避免误伤未做完的子项。

7. **Things 式进度环**  
   列表和仪表盘用字母大小的进度环，一眼看到完成比例；不必另做一份分析报表。

8. **状态与完成是两套概念**（Linear / 滴答看板）  
   `todo` / `in_progress` / `done` / `cancelled`。勾选完成会写入状态和完成时间；取消则退出范围但不当作完成。

9. **里程碑**（Asana / Linear）  
   任务可标为里程碑，在仪表盘单独分组，表示节点而不是普通步骤。

10. **旗标 / 今天**（Apple Reminders Flagged，Things 的 Today 星标，Microsoft To Do My Day）  
    不改日期也能把任务放进「今天」。

11. **日期约束只警告，不阻断**  
    开始晚于截止、子任务落在父任务时间窗之外时提示，但允许保存（计划会改）。

12. **不把加密加在任务数据上**  
    任务字段写在现有块的 `payload` 里，明文随现有 LWW 同步。传输层继续走 `syncnotes-seal-v1`，不拆掉，也不新增会毁数据的存储加密。

### 明确不做（本轮）

- 指派他人、评论、依赖关系、重复规则、Gantt / 工时估算、历史燃尽图（Linear 那种需要时序数据）
- 独立网页版（另开任务，与本功能分开）
- 改收件箱顶栏或全局转场动画

## 2. 信息架构与界面

### 入口

侧边栏在「收件箱」和「设置」之间增加「任务」。角标显示逾期数量。宽屏与窄屏抽屉都走同一入口。任务也可以出现在收件箱 / 文件夹里，点击进入同一套详情页。`Ctrl+K` 快速切换可搜到任务。

### 仪表盘

1. 顶栏：标题「任务」、筛选（今天 / 即将 / …）、排序、新建  
2. 总览条（仅在「总览」视图）：完成环 + 五张计数卡片，点卡片进入对应智能列表  
3. 任务列表：进度环、标题、优先级、日期、进度百分数、逾期 / 风险标记；已完成区折叠在底部（与收件箱一致）  
4. 空状态说明如何新建任务、拆进度项

### 任务详情 / 编辑

- 标题、备注  
- 状态、优先级、旗标、里程碑  
- 开始、截止、完成时间（完成时间在勾选后可改）  
- 进度模式与总进度条  
- 进度组成：增删改排序、权重、类型、起止时间；百分比类型可填完成比例  
- 子任务列表：每项可点进下一层，显示自己的进度与日期；添加子任务

返回键：详情页先返回仪表盘（或上一层任务），仪表盘再返回原来的页面。

## 3. 数据模型与协议

### 为什么用新 kind `task`

服务器把 `kind` 当原始字符串存储，未知类型可原样往返。协议版本保持 `3`，只在 `/health` 的 `features` 里增加 `"tasks"`。旧客户端不认识 `task` 时按未知块显示，不会打断同步、离线队列或回收站。

旧版客户端（v0.7.2 及更早）若对任务做 upsert（例如移入回收站），可能把 `kind` 写成 `unknown`。为此：

- `payload.is_task = true` 作为标记，新客户端即使看到 `kind=unknown` 也能恢复为任务  
- v0.8.0 客户端保存 `kindRaw`（线上原始类型字符串），以后遇到未知类型再 upsert 时不再改写成 `unknown`

存储不新增表，不加密 payload。父子关系沿用 `parent_id`：子任务的父是任务，文件夹里的任务父是文件夹。删除父任务时，子任务随祖先进入回收站隐藏，逻辑与文件夹相同。

### Payload（schema = 1）

```json
{
  "schema": 1,
  "is_task": true,
  "status": "todo",
  "priority": 3,
  "start_at": 1730000000000,
  "due_at": 1730600000000,
  "completed_at": null,
  "all_day": true,
  "progress_mode": "weighted",
  "manual_progress": 0,
  "auto_complete_parent": true,
  "auto_complete_children": false,
  "notes": "",
  "milestone": false,
  "flagged": false,
  "progress_items": [
    {
      "id": "uuid",
      "title": "设计稿",
      "weight": 30,
      "kind": "check",
      "done": false,
      "percent": 0,
      "subtask_id": null,
      "start_at": null,
      "due_at": null,
      "completed_at": null
    }
  ]
}
```

字段说明：

- `status`：`todo` | `in_progress` | `done` | `cancelled`  
- `priority`：0 无、1 低、2 中、3 高、4 紧急（同时用于现有收件箱 `payload.priority` 排序）  
- `progress_mode`：`weighted` | `equal` | `manual`  
- `progress_items[].kind`：`check`（完成则贡献全部权重）、`percent`（0–1 部分完成）、`subtask`（按子任务块的进度滚入）  
- 勾选完成时同步写 `completed: true` 与 `completed_at`，与收件箱已有完成标记兼容  
- 时间均为 Unix 毫秒；`all_day` 为真时按本地日历日比较逾期，不算时刻

未出现在 `progress_items` 里的子任务，默认按权重 1 自动计入，避免「建了子任务却看不到进度变化」。

### 进度计算

设每个组成项贡献 `ratio * weight`，`ratio` 为：

- 已取消的关联子任务：从分母排除  
- `check`：完成 1，否则 0  
- `percent`：`clamp(percent, 0, 1)`  
- `subtask`：子任务自身进度（递归，深度上限 5）  
- 父任务 `status=done`：自身进度为 1  
- `manual` 模式：用 `manual_progress`，忽略组成项（组成项仍保存，切回加权 / 均分时继续用）

均分模式把每项权重视为 1。没有组成项且不是手动模式时：`done=1`，否则 `0`。分母为 0 时进度为 0。

全部组成项（计入的）都完成后，若 `auto_complete_parent` 为真，将父任务标为完成。

### 向后兼容

- 协议版本不升，只加 feature flag  
- 旧客户端：未知 kind 照常同步；payload 对它们是不透明 JSON  
- 新客户端能识别 `kind=task` 或 `is_task=true`  
- 笔记上已有的 `completed` / `priority` 不受影响

## 4. 文件与改动范围

- `docs/task-dashboard.md`：本文  
- `app/lib/tasks/`：模型、进度、智能列表（纯 Dart，便于测试）  
- `app/lib/ui/task_dashboard_page.dart`、`task_editor_page.dart`：界面  
- `app/lib/models/block.dart`：`BlockKind.task` + 保留 `kindRaw`  
- `app/lib/blocks/builtin_types.dart`：注册 `TaskType`  
- `app/lib/ui/app_shell.dart`、`sidebar.dart`：只加入口  
- `app/lib/ui/quick_switcher.dart`、通知、回收站类型标签：小补  
- `server/src/blocks.rs`、`sync.rs`：识别 `task`，health 增加 `tasks`  
- 测试：`app/test/task_dashboard_test.dart` 以及必要时补充返回键 / 同步用例

不修改共享顶栏组件，不为任务单独改动效或玻璃着色器。
