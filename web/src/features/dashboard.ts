/**
 * Reserved surface for the upcoming native "任务仪表盘" (task dashboard).
 *
 * Another change set is adding the dashboard to the Flutter clients. Until
 * that lands on main, the web client keeps the existing block kinds and
 * exposes a stable hook so a later revision can render `dashboard_task`
 * (or whatever kind the native client settles on) without rewriting sync.
 *
 * Do not invent a new kind and start writing it to the server from this
 * client — unknown kinds already round-trip, but a premature schema would
 * drift from the official one.
 */

import type { Block } from '../protocol/types';

/** Likely kind string; treat as opaque until the native schema is published. */
export const DASHBOARD_KIND_CANDIDATES = ['dashboard_task', 'task', 'dashboard'] as const;

export interface DashboardTaskDraft {
  title: string;
  importance?: number;
  startAt?: number;
  dueAt?: number;
  completedAt?: number | null;
  steps?: Array<{
    id: string;
    title: string;
    weight: number;
    startAt?: number;
    dueAt?: number;
    done?: boolean;
  }>;
}

export function isDashboardBlock(b: Block): boolean {
  return (DASHBOARD_KIND_CANDIDATES as readonly string[]).includes(b.kind);
}

export function dashboardProgress(b: Block): number | null {
  const p = b.payload;
  if (typeof p.progress === 'number' && Number.isFinite(p.progress)) return clamp01(p.progress);
  const steps = p.steps;
  if (!Array.isArray(steps) || steps.length === 0) return null;
  let weight = 0;
  let done = 0;
  for (const s of steps) {
    if (!s || typeof s !== 'object') continue;
    const step = s as Record<string, unknown>;
    const w = typeof step.weight === 'number' && step.weight > 0 ? step.weight : 1;
    weight += w;
    if (step.done === true || step.completed === true) done += w;
  }
  return weight === 0 ? null : clamp01(done / weight);
}

function clamp01(n: number): number {
  if (n < 0) return 0;
  if (n > 1) return 1;
  return n;
}

/** Placeholder renderer flag used by the shell. Always false until schema lands. */
export function dashboardReady(): boolean {
  return false;
}
