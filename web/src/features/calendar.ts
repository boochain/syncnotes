/**
 * 日历（kind = "calendar"）的只读解析：订阅、重要日、倒数日、日程。
 *
 * 载荷格式以原生客户端为准（docs/calendar.md，schema = 1）。日期是公历 YYYY-MM-DD，
 * 不转时间戳，避免时区把“那天”挪走。网页版只读，不写回日历块。
 */

import type { Block } from '../protocol/types';
import { isTaskBlock, taskData } from './tasks';

export type CalendarRole = 'event' | 'subscription' | 'important' | 'countdown';
export type BillingCycle = 'weekly' | 'monthly' | 'quarterly' | 'yearly' | 'custom' | 'once';

export interface Ymd {
  y: number;
  m: number;
  d: number;
}

export function isCalendarBlock(b: Block): boolean {
  return b.kind === 'calendar';
}

export function parseYmd(v: unknown): Ymd | null {
  if (typeof v !== 'string') return null;
  const m = /^(\d{4})-(\d{1,2})-(\d{1,2})/.exec(v.trim());
  if (!m) return null;
  const y = Number(m[1]);
  const mo = Number(m[2]);
  const d = Number(m[3]);
  if (mo < 1 || mo > 12 || d < 1 || d > 31) return null;
  return { y, m: mo, d };
}

export function ymdOf(date: Date): Ymd {
  return { y: date.getFullYear(), m: date.getMonth() + 1, d: date.getDate() };
}

export function fmtYmd(v: Ymd): string {
  return `${v.y}-${String(v.m).padStart(2, '0')}-${String(v.d).padStart(2, '0')}`;
}

const utc = (v: Ymd) => Date.UTC(v.y, v.m - 1, v.d);
export const cmp = (a: Ymd, b: Ymd) => utc(a) - utc(b);
export const daysBetween = (from: Ymd, to: Ymd) => Math.round((utc(to) - utc(from)) / 86_400_000);

export function addDays(v: Ymd, n: number): Ymd {
  const t = new Date(utc(v) + n * 86_400_000);
  return { y: t.getUTCFullYear(), m: t.getUTCMonth() + 1, d: t.getUTCDate() };
}

export function addMonths(v: Ymd, n: number): Ymd {
  const total = v.y * 12 + (v.m - 1) + n;
  const y = Math.floor(total / 12);
  const m = (total % 12) + 1;
  const last = new Date(Date.UTC(y, m, 0)).getUTCDate();
  return { y, m, d: Math.min(v.d, last) };
}

export interface Billing {
  cycle: BillingCycle;
  interval: number;
  unit: 'day' | 'week' | 'month' | 'year';
  autoRenew: boolean;
  amount: number | null;
  currency: string;
  status: string;
  trialEnds: Ymd | null;
  lastPaid: Ymd | null;
}

export interface CalendarEntry {
  id: string;
  title: string;
  role: CalendarRole;
  start: Ymd;
  end: Ymd | null;
  startTime: string | null;
  yearly: boolean;
  countMode: 'both' | 'countdown' | 'countup';
  pinned: boolean;
  notes: string;
  billing: Billing | null;
}

function roleOf(v: unknown): CalendarRole {
  return v === 'subscription' || v === 'important' || v === 'countdown' ? v : 'event';
}

export function calendarEntry(b: Block): CalendarEntry | null {
  const p = b.payload;
  const start = parseYmd(p.start_date);
  if (!start) return null;
  const role = roleOf(p.role);
  const recur = p.recur && typeof p.recur === 'object' ? (p.recur as Record<string, unknown>) : {};
  const count = p.count && typeof p.count === 'object' ? (p.count as Record<string, unknown>) : {};
  const bl = p.billing && typeof p.billing === 'object' ? (p.billing as Record<string, unknown>) : null;
  const cycles: BillingCycle[] = ['weekly', 'monthly', 'quarterly', 'yearly', 'custom', 'once'];
  const billing: Billing | null = bl
    ? {
        cycle: cycles.includes(bl.cycle as BillingCycle) ? (bl.cycle as BillingCycle) : 'monthly',
        interval: typeof bl.interval === 'number' && bl.interval >= 1 ? Math.trunc(bl.interval) : 1,
        unit: bl.interval_unit === 'day' || bl.interval_unit === 'week' || bl.interval_unit === 'year' ? bl.interval_unit : 'month',
        autoRenew: bl.auto_renew === true,
        amount: typeof bl.amount === 'number' ? bl.amount : null,
        currency: typeof bl.currency === 'string' && bl.currency ? bl.currency : 'CNY',
        status: typeof bl.status === 'string' ? bl.status : 'active',
        trialEnds: parseYmd(bl.trial_ends),
        lastPaid: parseYmd(bl.last_paid),
      }
    : null;
  return {
    id: b.id,
    title: b.title || '未命名',
    role,
    start,
    end: parseYmd(p.end_date),
    startTime: typeof p.start_time === 'string' ? p.start_time : null,
    yearly: count.repeat_yearly === true || recur.freq === 'yearly',
    countMode: count.mode === 'countdown' || count.mode === 'countup' ? count.mode : 'both',
    pinned: p.pinned === true,
    notes: typeof p.notes === 'string' ? p.notes : '',
    billing,
  };
}

export function advanceBilling(b: Billing, start: Ymd, periods: number): Ymd {
  if (periods <= 0 || b.cycle === 'once') return start;
  const n = b.interval * periods;
  switch (b.cycle) {
    case 'weekly':
      return addDays(start, 7 * n);
    case 'monthly':
      return addMonths(start, n);
    case 'quarterly':
      return addMonths(start, 3 * n);
    case 'yearly':
      return addMonths(start, 12 * n);
    default:
      return b.unit === 'day' ? addDays(start, n) : b.unit === 'week' ? addDays(start, 7 * n) : b.unit === 'year' ? addMonths(start, 12 * n) : addMonths(start, n);
  }
}

/** 下次扣款日（与原生 nextBillingDate 一致的简化版）。暂停 / 取消 / 到期返回 null。 */
export function nextBilling(e: CalendarEntry, today: Ymd): Ymd | null {
  const b = e.billing;
  if (!b) return null;
  if (b.status === 'paused' || b.status === 'cancelled' || b.status === 'expired') return null;
  if (b.trialEnds && cmp(today, b.trialEnds) <= 0) return b.trialEnds;
  if (b.cycle === 'once' || !b.autoRenew) return cmp(e.start, today) >= 0 ? e.start : null;
  if (e.end && cmp(today, e.end) > 0) return null;
  for (let n = 0; n < 20000; n++) {
    const c = advanceBilling(b, e.start, n);
    if (cmp(c, today) >= 0 && (!b.lastPaid || cmp(c, b.lastPaid) > 0)) {
      return e.end && cmp(c, e.end) > 0 ? null : c;
    }
  }
  return null;
}

function nextAnniversary(start: Ymd, today: Ymd): Ymd {
  let c = { ...start };
  let k = 0;
  while (cmp(c, today) < 0 && k < 400) c = addMonths(start, 12 * ++k);
  return c;
}

/** 条目“下一次”的日期：订阅取下次扣款或到期日；按年重复的取下一个周年；其余取开始日。 */
export function nextDate(e: CalendarEntry, today: Ymd): Ymd | null {
  if (e.role === 'subscription') return nextBilling(e, today) ?? e.end;
  if (e.yearly) return nextAnniversary(e.start, today);
  return e.start;
}

export function countdownPhrase(today: Ymd, target: Ymd, mode: CalendarEntry['countMode'] = 'both'): string {
  const days = daysBetween(today, target);
  if (days === 0) return '就是今天';
  if (days > 0) return mode === 'countup' ? '已经 0 天' : `还有 ${days} 天`;
  return mode === 'countdown' ? `已过 ${-days} 天` : `已经 ${-days} 天`;
}

export const ROLE_LABELS: Record<CalendarRole, string> = {
  event: '日程',
  subscription: '订阅',
  important: '重要日',
  countdown: '倒数日',
};

export function cycleLabel(b: Billing): string {
  const n = b.interval;
  switch (b.cycle) {
    case 'weekly':
      return n === 1 ? '每周' : `每 ${n} 周`;
    case 'monthly':
      return n === 1 ? '单月' : `每 ${n} 个月`;
    case 'quarterly':
      return n === 1 ? '单季度' : `每 ${n} 个季度`;
    case 'yearly':
      return n === 1 ? '单年' : `每 ${n} 年`;
    case 'once':
      return '一次性';
    default:
      return `每 ${n} ${b.unit === 'day' ? '天' : b.unit === 'week' ? '周' : b.unit === 'year' ? '年' : '个月'}`;
  }
}

export interface AgendaRow {
  id: string;
  title: string;
  date: Ymd;
  source: 'calendar' | 'task';
  role: CalendarRole | null;
  subtitle: string;
  pinned: boolean;
}

/** 未来 [horizon] 天内的日程 + 带日期的未完成任务（任务只读叠加，与原生日历一致）。 */
export function agenda(blocks: Iterable<Block>, today: Ymd, horizon = 60): AgendaRow[] {
  const out: AgendaRow[] = [];
  const limit = addDays(today, horizon);
  for (const b of blocks) {
    if (b.deleted || b.deleted_at != null) continue;
    if (isCalendarBlock(b)) {
      const e = calendarEntry(b);
      if (!e) continue;
      const d = nextDate(e, today);
      if (!d) continue;
      const span = e.end && e.role === 'event' ? e.end : d;
      if (cmp(span, today) < 0 || cmp(d, limit) > 0) continue;
      let sub = ROLE_LABELS[e.role];
      if (e.billing) sub += ` · ${cycleLabel(e.billing)}${e.billing.autoRenew ? ' · 自动续费' : ''}`;
      if (e.role !== 'event') sub += ` · ${countdownPhrase(today, d, e.countMode)}`;
      out.push({ id: e.id, title: e.title, date: d, source: 'calendar', role: e.role, subtitle: sub, pinned: e.pinned });
    } else if (isTaskBlock(b)) {
      const t = taskData(b);
      if (t.status === 'done' || t.status === 'cancelled') continue;
      const ms = t.dueAt ?? t.startAt;
      if (ms == null) continue;
      const d = ymdOf(new Date(ms));
      if (cmp(d, limit) > 0) continue;
      const overdue = cmp(d, today) < 0;
      out.push({
        id: b.id,
        title: b.title || '任务',
        date: overdue ? today : d,
        source: 'task',
        role: null,
        subtitle: overdue ? `任务 · 已逾期 ${daysBetween(d, today)} 天` : '任务',
        pinned: false,
      });
    }
  }
  return out.sort((a, b) => cmp(a.date, b.date) || Number(b.pinned) - Number(a.pinned) || a.title.localeCompare(b.title));
}
