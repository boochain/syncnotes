import { useEffect, useState } from 'react';
import type { SyncEngine } from '../sync/engine';
import { Icons } from '../ui/icons';
import {
  PRIORITY_LABELS,
  STATUS_LABELS,
  formatTaskDate,
  isOverdue,
  isTaskBlock,
  sortedRootTasks,
  subtasksOf,
  taskData,
  taskProgress,
  toggledTaskPayload,
} from '../features/tasks';
import type { Block } from '../protocol/types';

type TaskFilter = 'open' | 'overdue' | 'done' | 'all';

const PRIORITY_COLORS = ['var(--text3)', '#34C759', '#FF9F0A', '#FF453A', '#BF5AF2'];

/**
 * 网页版任务列表：查看任务、加权进度、组成项与子任务，可勾选完成。
 * 新建 / 编辑组成项与权重请在桌面或手机客户端完成（见 release notes）。
 */
export function TasksPage({ sync, tick, focus, onClose }: { sync: SyncEngine; tick: number; focus?: string; onClose: () => void }) {
  const [filter, setFilter] = useState<TaskFilter>('open');
  const [open, setOpen] = useState<string | null>(focus ?? null);
  const [, setT] = useState(0);
  useEffect(() => sync.subscribe(() => setT((n) => n + 1)), [sync]);
  void tick;

  const all = sync.blockMap();
  const visible = sync.visible().filter(isTaskBlock);
  const roots = sortedRootTasks(visible, all);
  const now = Date.now();
  const counts = {
    open: roots.filter((b) => !['done', 'cancelled'].includes(taskData(b).status)).length,
    overdue: roots.filter((b) => isOverdue(b, now)).length,
    done: roots.filter((b) => taskData(b).status === 'done').length,
  };
  const shown = roots.filter((b) => {
    const s = taskData(b).status;
    if (filter === 'open') return s !== 'done' && s !== 'cancelled';
    if (filter === 'overdue') return isOverdue(b, now);
    if (filter === 'done') return s === 'done' || s === 'cancelled';
    return true;
  });

  return (
    <section className="page glass" aria-label="任务">
      <header className="page-head">
        <button className="icon-btn" onClick={onClose} aria-label="返回"><Icons.back /></button>
        <h2>任务</h2>
      </header>
      <div className="page-body">
        <div className="stat-row">
          <div className="stat glass-lite"><b>{counts.open}</b><span>进行中</span></div>
          <div className="stat glass-lite"><b style={{ color: counts.overdue ? 'var(--danger)' : undefined }}>{counts.overdue}</b><span>已逾期</span></div>
          <div className="stat glass-lite"><b>{counts.done}</b><span>已完成</span></div>
        </div>
        <div className="toolbar" style={{ padding: '4px 0 12px' }}>
          {(['open', 'overdue', 'done', 'all'] as TaskFilter[]).map((f) => (
            <button key={f} className={`pill ${filter === f ? 'active' : ''}`} onClick={() => setFilter(f)}>
              {f === 'open' ? '未完成' : f === 'overdue' ? '逾期' : f === 'done' ? '已完成' : '全部'}
            </button>
          ))}
        </div>
        {shown.length === 0 && (
          <div className="empty">{visible.length === 0 ? '还没有任务。在桌面或手机客户端的「任务」里新建后，这里会同步显示。' : '这个筛选下没有任务'}</div>
        )}
        {shown.map((b) => (
          <TaskRow key={b.id} block={b} sync={sync} all={all} expanded={open === b.id} onToggleOpen={() => setOpen(open === b.id ? null : b.id)} depth={0} now={now} />
        ))}
      </div>
    </section>
  );
}

function TaskRow({ block, sync, all, expanded, onToggleOpen, depth, now }: {
  block: Block;
  sync: SyncEngine;
  all: ReadonlyMap<string, Block>;
  expanded: boolean;
  onToggleOpen: () => void;
  depth: number;
  now: number;
}) {
  const d = taskData(block);
  const progress = taskProgress(block, all);
  const overdue = isOverdue(block, now);
  const done = d.status === 'done';
  const subs = subtasksOf(block.id, all);
  const dates = [d.startAt != null ? `开始 ${formatTaskDate(d.startAt, d.allDay)}` : '', d.dueAt != null ? `截止 ${formatTaskDate(d.dueAt, d.allDay)}` : '']
    .filter(Boolean)
    .join(' · ');
  return (
    <div className="task-row" style={{ marginLeft: depth * 20 }} data-testid={`task-${block.id}`}>
      <div className="list-row">
        <button
          className="icon-btn"
          aria-label={done ? '取消完成' : '标为已完成'}
          onClick={() => sync.update(block.id, { payload: toggledTaskPayload(block) })}
          style={{ color: done ? 'var(--success)' : 'var(--text2)' }}
        >
          {done ? <Icons.checkCircle /> : <Icons.circle />}
        </button>
        <div style={{ flex: 1, minWidth: 0, cursor: 'pointer' }} onClick={onToggleOpen}>
          <div className={`title ${done ? 'done' : ''}`}>
            {d.flagged ? '⚑ ' : ''}{d.milestone ? '◆ ' : ''}{block.title || '无标题任务'}
          </div>
          <div className="hint" style={{ display: 'flex', gap: 8, flexWrap: 'wrap' }}>
            {d.priority > 0 && <span style={{ color: PRIORITY_COLORS[d.priority] }}>优先级 {PRIORITY_LABELS[d.priority]}</span>}
            <span>{STATUS_LABELS[d.status]}</span>
            {dates && <span style={{ color: overdue ? 'var(--danger)' : undefined }}>{dates}{overdue ? '（已逾期）' : ''}</span>}
            {subs.length > 0 && <span>{subs.length} 个子任务</span>}
          </div>
        </div>
        <div style={{ width: 110, display: 'flex', alignItems: 'center', gap: 8 }}>
          <div className="progress"><span style={{ width: `${Math.round(progress * 100)}%`, background: overdue ? 'var(--danger)' : done ? 'var(--success)' : undefined }} /></div>
          <span className="hint" style={{ width: 34, textAlign: 'right' }}>{Math.round(progress * 100)}%</span>
        </div>
      </div>
      {expanded && (
        <div className="task-detail">
          {d.notes && <p className="hint" style={{ whiteSpace: 'pre-wrap' }}>{d.notes}</p>}
          {d.items.length > 0 && (
            <>
              <div className="section-h">进度组成（{d.progressMode === 'weighted' ? '按权重' : d.progressMode === 'equal' ? '均分' : '手动'}）</div>
              {d.items.map((it) => {
                const ratio = it.kind === 'check' ? (it.done ? 1 : 0) : it.kind === 'percent' ? Math.max(0, Math.min(1, it.percent)) : (() => {
                  const c = it.subtaskId ? all.get(it.subtaskId) : undefined;
                  return c ? taskProgress(c, all) : 0;
                })();
                return (
                  <div key={it.id} className="list-row" style={{ padding: '6px 4px' }}>
                    <span style={{ flex: 1, minWidth: 0 }}>{it.title || '未命名'}</span>
                    {d.progressMode === 'weighted' && <span className="hint">权重 {it.weight}</span>}
                    <span className="hint" style={{ width: 40, textAlign: 'right' }}>{Math.round(ratio * 100)}%</span>
                  </div>
                );
              })}
            </>
          )}
          {d.progressMode === 'manual' && <p className="hint">手动进度：{Math.round(d.manualProgress * 100)}%</p>}
          {subs.length > 0 && <div className="section-h">子任务</div>}
          {subs.map((c) => (
            <SubtaskRow key={c.id} block={c} sync={sync} all={all} depth={1} now={now} />
          ))}
          {d.completedAt != null && done && <p className="hint">完成于 {formatTaskDate(d.completedAt, false)}</p>}
        </div>
      )}
    </div>
  );
}

function SubtaskRow({ block, sync, all, depth, now }: { block: Block; sync: SyncEngine; all: ReadonlyMap<string, Block>; depth: number; now: number }) {
  const [open, setOpen] = useState(false);
  return <TaskRow block={block} sync={sync} all={all} expanded={open} onToggleOpen={() => setOpen(!open)} depth={depth} now={now} />;
}
