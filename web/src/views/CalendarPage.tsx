import { useEffect, useState } from 'react';
import type { SyncEngine } from '../sync/engine';
import { Icons } from '../ui/icons';
import {
  ROLE_LABELS,
  agenda,
  calendarEntry,
  countdownPhrase,
  cycleLabel,
  fmtYmd,
  isCalendarBlock,
  nextBilling,
  nextDate,
  ymdOf,
  type CalendarEntry,
  type CalendarRole,
} from '../features/calendar';

type Tab = 'agenda' | 'subscription' | 'countdown';

const ROLE_COLORS: Record<CalendarRole, string> = {
  event: '#0A84FF',
  subscription: '#FF9F0A',
  important: '#FF453A',
  countdown: '#BF5AF2',
};

const STATUS_LABELS: Record<string, string> = {
  active: '使用中',
  trial: '试用中',
  paused: '已暂停',
  cancelled: '已取消',
  expired: '已到期',
  pending: '待续',
};

/**
 * 网页版日历（只读）：近期日程（含带日期的任务）、会员订阅、重要日与倒数日。
 * 新建和编辑日历条目请在桌面或手机客户端完成。
 */
export function CalendarPage({ sync, tick, onClose }: { sync: SyncEngine; tick: number; onClose: () => void }) {
  const [tab, setTab] = useState<Tab>('agenda');
  const [, setT] = useState(0);
  useEffect(() => sync.subscribe(() => setT((n) => n + 1)), [sync]);
  void tick;

  const today = ymdOf(new Date());
  const blocks = sync.visible();
  const entries = blocks.filter(isCalendarBlock).map(calendarEntry).filter((e): e is CalendarEntry => e != null);
  const rows = agenda(blocks, today, 60);
  const subs = entries.filter((e) => e.role === 'subscription');
  const counts = entries.filter((e) => e.role === 'countdown' || e.role === 'important');
  const monthly = subs.reduce((sum, e) => sum + monthlyCost(e), 0);

  return (
    <section className="page glass" aria-label="日历">
      <header className="page-head">
        <button className="icon-btn" onClick={onClose} aria-label="返回"><Icons.back /></button>
        <h2>日历</h2>
        <span className="hint">{fmtYmd(today)}</span>
      </header>
      <div className="page-body">
        <div className="toolbar" style={{ padding: '4px 0 12px' }}>
          {(['agenda', 'subscription', 'countdown'] as Tab[]).map((t) => (
            <button key={t} className={`pill ${tab === t ? 'active' : ''}`} onClick={() => setTab(t)}>
              {t === 'agenda' ? '近期' : t === 'subscription' ? `订阅 · ${subs.length}` : `倒数日 · ${counts.length}`}
            </button>
          ))}
        </div>
        {tab === 'agenda' && (
          <>
            {rows.length === 0 && <div className="empty">未来 60 天没有日程。可以在桌面或手机客户端的「日历」里新建订阅、重要日和倒数日。</div>}
            {rows.map((r) => (
              <div key={`${r.source}-${r.id}`} className="list-row">
                <span className="cal-date">{r.date.m}/{r.date.d}</span>
                <span className="cal-dot" style={{ background: r.source === 'task' ? '#30D158' : ROLE_COLORS[r.role ?? 'event'] }} />
                <div style={{ flex: 1, minWidth: 0 }}>
                  <div className="title">{r.pinned ? '📌 ' : ''}{r.title}</div>
                  <div className="hint">{r.subtitle}</div>
                </div>
              </div>
            ))}
          </>
        )}
        {tab === 'subscription' && (
          <>
            {subs.length > 0 && <p className="hint">折合每月约 {monthly.toFixed(2)}（按各订阅自己的币种直接相加，仅供参考）</p>}
            {subs.length === 0 && <div className="empty">还没有订阅</div>}
            {subs.map((e) => {
              const next = nextBilling(e, today);
              const b = e.billing;
              return (
                <div key={e.id} className="list-row">
                  <span className="cal-dot" style={{ background: ROLE_COLORS.subscription }} />
                  <div style={{ flex: 1, minWidth: 0 }}>
                    <div className="title">{e.title}</div>
                    <div className="hint">
                      {b ? `${cycleLabel(b)} · ${b.autoRenew ? '自动续费' : '不自动续费'} · ${STATUS_LABELS[b.status] ?? b.status}` : '订阅'}
                      {` · 开始 ${fmtYmd(e.start)}`}
                      {e.end ? ` · 结束 ${fmtYmd(e.end)}` : ''}
                    </div>
                  </div>
                  <div style={{ textAlign: 'right' }}>
                    {b?.amount != null && <div className="title" style={{ fontSize: 14 }}>{b.currency} {b.amount}</div>}
                    <div className="hint">{next ? `${fmtYmd(next)} · ${countdownPhrase(today, next)}` : '无下次扣款'}</div>
                  </div>
                </div>
              );
            })}
          </>
        )}
        {tab === 'countdown' && (
          <>
            {counts.length === 0 && <div className="empty">还没有重要日或倒数日</div>}
            {counts
              .map((e) => ({ e, d: nextDate(e, today) ?? e.start }))
              .sort((a, b) => Number(b.e.pinned) - Number(a.e.pinned) || fmtYmd(a.d).localeCompare(fmtYmd(b.d)))
              .map(({ e, d }) => (
                <div key={e.id} className="list-row">
                  <span className="cal-dot" style={{ background: ROLE_COLORS[e.role] }} />
                  <div style={{ flex: 1, minWidth: 0 }}>
                    <div className="title">{e.pinned ? '📌 ' : ''}{e.title}</div>
                    <div className="hint">{ROLE_LABELS[e.role]} · {fmtYmd(d)}{e.yearly ? ' · 每年' : ''}</div>
                  </div>
                  <b className="countdown">{countdownPhrase(today, d, e.countMode)}</b>
                </div>
              ))}
          </>
        )}
      </div>
    </section>
  );
}

function monthlyCost(e: CalendarEntry): number {
  const b = e.billing;
  if (!b || b.amount == null || !b.amount) return 0;
  if (b.status === 'paused' || b.status === 'cancelled' || b.status === 'expired') return 0;
  const n = b.interval;
  switch (b.cycle) {
    case 'monthly':
      return b.amount / n;
    case 'quarterly':
      return b.amount / (3 * n);
    case 'yearly':
      return b.amount / (12 * n);
    case 'weekly':
      return (b.amount * 52) / 12 / n;
    case 'once':
      return 0;
    default:
      return b.unit === 'day' ? (b.amount * 365.25) / 12 / n : b.unit === 'week' ? (b.amount * 52) / 12 / n : b.unit === 'year' ? b.amount / 12 / n : b.amount / n;
  }
}
