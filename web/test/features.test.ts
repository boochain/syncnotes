import { describe, expect, it } from 'vitest';
import { SyncEngine } from '../src/sync/engine';
import { blockFromServer, isInboxItem, toUpsertMessage, type Block } from '../src/protocol/types';
import { isOverdue, isTaskBlock, sortedRootTasks, taskData, taskProgress, toggledTaskPayload } from '../src/features/tasks';
import { agenda, calendarEntry, countdownPhrase, nextBilling, nextDate, parseYmd } from '../src/features/calendar';

function blk(p: Partial<Block> & Pick<Block, 'id'>): Block {
  return blockFromServer({
    kind: 'task',
    title: p.id,
    payload: {},
    viewed_mode: 'global',
    created_at: 1,
    updated_at: 1,
    created_by: 'x',
    deleted: false,
    ...p,
  } as Record<string, unknown>);
}

const map = (...bs: Block[]) => new Map(bs.map((b) => [b.id, b]));

describe('tasks', () => {
  it('computes weighted progress with check, percent and auto-listed subtasks', () => {
    const parent = blk({
      id: 'p',
      payload: {
        is_task: true,
        progress_mode: 'weighted',
        progress_items: [
          { id: 'a', title: '设计', weight: 30, kind: 'check', done: true },
          { id: 'b', title: '实现', weight: 50, kind: 'percent', percent: 0.5 },
        ],
      },
    });
    const child = blk({ id: 'c', parent_id: 'p', payload: { is_task: true, status: 'done' } });
    // (30*1 + 50*0.5 + 1*1) / 81
    expect(taskProgress(parent, map(parent, child))).toBeCloseTo(56 / 81, 6);
    expect(taskProgress(blk({ id: 'm', payload: { progress_mode: 'manual', manual_progress: 0.4 } }), map())).toBeCloseTo(0.4);
    expect(taskProgress(blk({ id: 'd', payload: { status: 'done' } }), map())).toBe(1);
  });

  it('equal mode ignores weights and cancelled subtasks are excluded', () => {
    const parent = blk({ id: 'p', payload: { progress_mode: 'equal', progress_items: [{ id: 'a', weight: 9, kind: 'check', done: true }] } });
    const c1 = blk({ id: 'c1', parent_id: 'p', payload: { status: 'todo' } });
    const c2 = blk({ id: 'c2', parent_id: 'p', payload: { status: 'cancelled' } });
    expect(taskProgress(parent, map(parent, c1, c2))).toBeCloseTo(0.5);
  });

  it('toggling done keeps unknown payload keys and the raw kind', () => {
    const t = blk({ id: 't', payload: { is_task: true, status: 'in_progress', future_key: { x: 1 }, progress_items: [] } });
    const done = toggledTaskPayload(t, 1234);
    expect(done).toMatchObject({ status: 'done', completed: true, completed_at: 1234, future_key: { x: 1 } });
    const back = toggledTaskPayload({ ...t, payload: done });
    expect(back.status).toBe('todo');
    expect(back.completed).toBeUndefined();
    expect(back.future_key).toEqual({ x: 1 });

    const e = new SyncEngine('web');
    e.markOnlineForTests();
    e.applyServerMessage({ type: 'block_update', block: { id: 't', kind: 'task', title: '任务', payload: t.payload, viewed_mode: 'global', created_at: 1, updated_at: 1, created_by: 'pc', deleted: false, seq: 1 } });
    const updated = e.update('t', { payload: done })!;
    expect(updated.kind).toBe('task');
    expect(toUpsertMessage(updated).kind).toBe('task');
  });

  it('overdue uses end of local day for all-day tasks, and sorts overdue / priority first', () => {
    const now = new Date(2026, 10, 28, 12).getTime();
    const todayDue = blk({ id: 'a', payload: { due_at: new Date(2026, 10, 28, 0).getTime(), all_day: true, priority: 1 } });
    const late = blk({ id: 'b', payload: { due_at: new Date(2026, 10, 27, 9).getTime(), all_day: false, priority: 0 } });
    const high = blk({ id: 'c', payload: { priority: 4 } });
    const finished = blk({ id: 'd', payload: { status: 'done', priority: 4 } });
    expect(isOverdue(todayDue, now)).toBe(false);
    expect(isOverdue(late, now)).toBe(true);
    const all = map(todayDue, late, high, finished);
    expect(sortedRootTasks(all.values(), all, now).map((b) => b.id)).toEqual(['b', 'c', 'a', 'd']);
  });

  it('recognises tasks written by an old client as unknown kind via is_task', () => {
    const b = blk({ id: 'x', kind: 'unknown', payload: { is_task: true, status: 'todo' } });
    expect(isTaskBlock(b)).toBe(true);
    expect(taskData(b).status).toBe('todo');
  });
});

describe('calendar', () => {
  const today = parseYmd('2026-11-28')!;

  it('keeps calendar blocks out of the inbox but tasks in it', () => {
    expect(isInboxItem(blk({ id: 'c', kind: 'calendar' }))).toBe(false);
    expect(isInboxItem(blk({ id: 't', kind: 'task' }))).toBe(true);
  });

  it('finds the next auto-renew billing date, including month-end clamping', () => {
    const sub = calendarEntry(blk({
      id: 's',
      kind: 'calendar',
      payload: { role: 'subscription', start_date: '2026-01-31', billing: { cycle: 'monthly', auto_renew: true, amount: 18 } },
    }))!;
    expect(nextBilling(sub, today)).toEqual({ y: 2026, m: 11, d: 30 });
    const yearly = calendarEntry(blk({
      id: 'y',
      kind: 'calendar',
      payload: { role: 'subscription', start_date: '2025-12-05', billing: { cycle: 'yearly', auto_renew: true } },
    }))!;
    expect(nextBilling(yearly, today)).toEqual({ y: 2026, m: 12, d: 5 });
    const single = calendarEntry(blk({
      id: 'o',
      kind: 'calendar',
      payload: { role: 'subscription', start_date: '2026-10-01', end_date: '2026-12-31', billing: { cycle: 'quarterly', auto_renew: false } },
    }))!;
    expect(nextBilling(single, today)).toBeNull();
    expect(nextDate(single, today)).toEqual({ y: 2026, m: 12, d: 31 });
    const paused = calendarEntry(blk({
      id: 'p',
      kind: 'calendar',
      payload: { role: 'subscription', start_date: '2026-01-01', billing: { cycle: 'monthly', auto_renew: true, status: 'paused' } },
    }))!;
    expect(nextBilling(paused, today)).toBeNull();
  });

  it('yearly countdowns roll to the next anniversary', () => {
    const bday = calendarEntry(blk({ id: 'b', kind: 'calendar', payload: { role: 'countdown', start_date: '1990-03-02', count: { repeat_yearly: true } } }))!;
    expect(nextDate(bday, today)).toEqual({ y: 2027, m: 3, d: 2 });
    expect(countdownPhrase(today, parseYmd('2026-12-01')!)).toBe('还有 3 天');
    expect(countdownPhrase(today, today)).toBe('就是今天');
    expect(countdownPhrase(today, parseYmd('2026-11-20')!)).toBe('已经 8 天');
  });

  it('agenda merges calendar entries with dated open tasks', () => {
    const cal = blk({ id: 'c', kind: 'calendar', title: '体检', payload: { role: 'important', start_date: '2026-12-02', pinned: true } });
    const task = blk({ id: 't', kind: 'task', title: '交稿', payload: { is_task: true, due_at: new Date(2026, 11, 2, 18).getTime() } });
    const doneTask = blk({ id: 'd', kind: 'task', title: '已完成', payload: { status: 'done', due_at: new Date(2026, 11, 2).getTime() } });
    const rows = agenda([cal, task, doneTask], today);
    expect(rows.map((r) => r.title)).toEqual(['体检', '交稿']);
    expect(rows[1].source).toBe('task');
  });
});
