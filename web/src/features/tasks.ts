/**
 * 任务（kind = "task"）的只读解析与少量安全写回。
 *
 * 载荷格式以原生客户端为准（docs/task-dashboard.md，schema = 1）。
 * 网页版只做：列表、加权进度、逾期判断、勾选完成 / 取消完成。
 * 写回时一律在原载荷上做浅拷贝修改，未识别的键原样保留。
 */

import type { Block } from '../protocol/types';

export type TaskStatus = 'todo' | 'in_progress' | 'done' | 'cancelled';
export type ProgressMode = 'weighted' | 'equal' | 'manual';

export interface ProgressItem {
  id: string;
  title: string;
  weight: number;
  kind: 'check' | 'percent' | 'subtask';
  done: boolean;
  percent: number;
  subtaskId: string | null;
}

export interface TaskData {
  status: TaskStatus;
  priority: number;
  startAt: number | null;
  dueAt: number | null;
  completedAt: number | null;
  allDay: boolean;
  progressMode: ProgressMode;
  manualProgress: number;
  notes: string;
  milestone: boolean;
  flagged: boolean;
  items: ProgressItem[];
}

export const PRIORITY_LABELS = ['无', '低', '中', '高', '紧急'] as const;
export const STATUS_LABELS: Record<TaskStatus, string> = {
  todo: '待办',
  in_progress: '进行中',
  done: '已完成',
  cancelled: '已取消',
};

export function isTaskBlock(b: Block): boolean {
  return b.kind === 'task' || b.payload.is_task === true;
}

function num(v: unknown): number | null {
  if (typeof v === 'number' && Number.isFinite(v)) return v;
  if (typeof v === 'string' && v.trim() && Number.isFinite(Number(v))) return Number(v);
  return null;
}

function statusFrom(v: unknown): TaskStatus {
  return v === 'in_progress' || v === 'done' || v === 'cancelled' ? v : 'todo';
}

export function taskData(b: Block): TaskData {
  const p = b.payload;
  let status = statusFrom(p.status);
  if (p.completed === true && status !== 'cancelled') status = 'done';
  const raw = Array.isArray(p.progress_items) ? p.progress_items : [];
  const items: ProgressItem[] = [];
  for (const e of raw) {
    if (!e || typeof e !== 'object') continue;
    const j = e as Record<string, unknown>;
    const kind = j.kind === 'percent' || j.kind === 'subtask' ? j.kind : 'check';
    items.push({
      id: String(j.id ?? ''),
      title: String(j.title ?? ''),
      weight: num(j.weight) ?? 1,
      kind,
      done: j.done === true,
      percent: num(j.percent) ?? 0,
      subtaskId: typeof j.subtask_id === 'string' ? j.subtask_id : null,
    });
  }
  const pr = num(p.priority) ?? 0;
  return {
    status,
    priority: Math.max(0, Math.min(4, Math.trunc(pr))),
    startAt: num(p.start_at),
    dueAt: num(p.due_at),
    completedAt: num(p.completed_at),
    allDay: p.all_day !== false,
    progressMode: p.progress_mode === 'equal' || p.progress_mode === 'manual' ? p.progress_mode : 'weighted',
    manualProgress: num(p.manual_progress) ?? 0,
    notes: typeof p.notes === 'string' ? p.notes : '',
    milestone: p.milestone === true,
    flagged: p.flagged === true,
    items,
  };
}

const clamp01 = (n: number) => (n < 0 ? 0 : n > 1 ? 1 : n);

function live(b: Block | undefined): b is Block {
  return !!b && !b.deleted && b.deleted_at == null && isTaskBlock(b);
}

/** 与原生 computeTaskProgress 相同的规则（加权 / 均分 / 手动，子任务递归，未列出的子任务按权重 1 计入）。 */
export function taskProgress(task: Block, all: ReadonlyMap<string, Block>, visiting: Set<string> = new Set()): number {
  const d = taskData(task);
  if (d.status === 'done') return 1;
  if (d.status === 'cancelled') return 0;
  if (d.progressMode === 'manual') return clamp01(d.manualProgress);
  const seen = new Set(visiting);
  seen.add(task.id);
  const items = [...d.items];
  const listed = new Set(items.filter((i) => i.kind === 'subtask' && i.subtaskId).map((i) => i.subtaskId!));
  for (const c of all.values()) {
    if (c.parent_id === task.id && live(c) && !listed.has(c.id)) {
      items.push({ id: `auto-${c.id}`, title: c.title, weight: 1, kind: 'subtask', done: false, percent: 0, subtaskId: c.id });
    }
  }
  let numr = 0;
  let den = 0;
  for (const it of items) {
    const w = d.progressMode === 'equal' ? 1 : it.weight;
    if (!(w > 0)) continue;
    if (it.kind === 'subtask') {
      const c = it.subtaskId ? all.get(it.subtaskId) : undefined;
      if (!live(c) || taskData(c).status === 'cancelled' || seen.has(c.id) || seen.size > 6) continue;
      den += w;
      numr += w * taskProgress(c, all, seen);
    } else if (it.kind === 'percent') {
      den += w;
      numr += w * clamp01(it.percent);
    } else {
      den += w;
      numr += it.done ? w : 0;
    }
  }
  return den === 0 ? 0 : clamp01(numr / den);
}

function endOfLocalDay(ms: number): number {
  const d = new Date(ms);
  return new Date(d.getFullYear(), d.getMonth(), d.getDate(), 23, 59, 59, 999).getTime();
}

export function isOverdue(b: Block, now = Date.now()): boolean {
  const d = taskData(b);
  if (d.status === 'done' || d.status === 'cancelled' || d.dueAt == null) return false;
  return (d.allDay ? endOfLocalDay(d.dueAt) : d.dueAt) < now;
}

/** 勾选 / 取消完成：同时写 status、completed、completed_at，保留其他键。 */
export function toggledTaskPayload(b: Block, now = Date.now()): Record<string, unknown> {
  const d = taskData(b);
  const next: Record<string, unknown> = { ...b.payload };
  if (d.status === 'done') {
    next.status = 'todo';
    delete next.completed;
    next.completed_at = null;
  } else {
    next.status = 'done';
    next.completed = true;
    next.completed_at = now;
  }
  return next;
}

export function formatTaskDate(ms: number | null, allDay: boolean): string {
  if (ms == null) return '';
  const d = new Date(ms);
  const day = `${d.getMonth() + 1}月${d.getDate()}日`;
  if (allDay) return day;
  return `${day} ${String(d.getHours()).padStart(2, '0')}:${String(d.getMinutes()).padStart(2, '0')}`;
}

/** 顶层任务（父不是任务）按：未完成在前 → 逾期 → 优先级高 → 截止早。 */
export function sortedRootTasks(blocks: Iterable<Block>, all: ReadonlyMap<string, Block>, now = Date.now()): Block[] {
  const out: Block[] = [];
  for (const b of blocks) {
    if (!live(b)) continue;
    const parent = b.parent_id ? all.get(b.parent_id) : undefined;
    if (parent && isTaskBlock(parent)) continue;
    out.push(b);
  }
  const rank = (b: Block) => {
    const s = taskData(b).status;
    return s === 'done' || s === 'cancelled' ? 1 : 0;
  };
  return out.sort((a, b) => {
    const r = rank(a) - rank(b);
    if (r) return r;
    const o = Number(isOverdue(b, now)) - Number(isOverdue(a, now));
    if (o) return o;
    const p = taskData(b).priority - taskData(a).priority;
    if (p) return p;
    const da = taskData(a).dueAt ?? Number.MAX_SAFE_INTEGER;
    const db = taskData(b).dueAt ?? Number.MAX_SAFE_INTEGER;
    return da - db || a.created_at - b.created_at;
  });
}

export function subtasksOf(id: string, all: ReadonlyMap<string, Block>): Block[] {
  return [...all.values()].filter((b) => b.parent_id === id && live(b)).sort((a, b) => a.created_at - b.created_at);
}
