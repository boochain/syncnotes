export type BlockKind = 'message' | 'note' | 'file' | 'folder' | 'page' | 'text' | 'task' | 'calendar' | 'unknown' | string;
export type ViewedMode = 'per_device' | 'global';
export type ConnState = 'offline' | 'connecting' | 'online' | 'authError';

export interface HealthResponse {
  status: string;
  version: string;
  protocol?: number;
  features?: string[];
  trash_retention_days?: number;
  seal_pub?: string;
}

export interface AuthResponse {
  token: string;
  user_id: string;
  username: string;
  recovery_code?: string | null;
  has_recovery_code?: boolean;
  must_change_password?: boolean;
}

export interface Block {
  id: string;
  kind: BlockKind;
  title: string;
  payload: Record<string, unknown>;
  parent_id: string | null;
  viewed_mode: ViewedMode;
  viewed_global: boolean;
  created_at: number;
  updated_at: number;
  created_by: string;
  deleted: boolean;
  deleted_at: number | null;
  deleted_by: string | null;
  seq: number;
  viewed_local: boolean;
  pending: boolean;
}

export function asInt(v: unknown): number {
  if (typeof v === 'number' && Number.isFinite(v)) return Math.trunc(v);
  if (typeof v === 'string' && v.trim()) {
    const n = Number(v);
    if (Number.isFinite(n)) return Math.trunc(n);
  }
  return 0;
}

export function asString(v: unknown, fallback = ''): string {
  return typeof v === 'string' ? v : fallback;
}

export function blockKindFrom(s: unknown): BlockKind {
  if (s === 'message' || s === 'note' || s === 'file' || s === 'folder' || s === 'page' || s === 'text') return s;
  if (typeof s === 'string' && s) return s;
  return 'unknown';
}

export function viewedModeFrom(s: unknown): ViewedMode {
  return s === 'global' ? 'global' : 'per_device';
}

export function blockFromServer(j: Record<string, unknown>, viewedLocal = false): Block {
  const payload =
    j.payload && typeof j.payload === 'object' && !Array.isArray(j.payload)
      ? { ...(j.payload as Record<string, unknown>) }
      : {};
  return {
    id: asString(j.id),
    kind: blockKindFrom(j.kind),
    title: asString(j.title),
    payload,
    parent_id: j.parent_id == null ? null : asString(j.parent_id),
    viewed_mode: viewedModeFrom(j.viewed_mode),
    viewed_global: j.viewed_global === true,
    created_at: asInt(j.created_at),
    updated_at: asInt(j.updated_at),
    created_by: asString(j.created_by),
    deleted: j.deleted === true,
    deleted_at: j.deleted_at == null ? null : asInt(j.deleted_at),
    deleted_by: j.deleted_by == null ? null : asString(j.deleted_by),
    seq: asInt(j.seq),
    viewed_local: viewedLocal,
    pending: false,
  };
}

export function inTrash(b: Block): boolean {
  return b.deleted_at != null && !b.deleted;
}

export function isViewed(b: Block): boolean {
  return b.viewed_mode === 'global' ? b.viewed_global : b.viewed_local;
}

/** 收件箱条目：不含页面内部的内容块；日历条目只在「日历」里显示（与原生客户端一致）。 */
export function isInboxItem(b: Block): boolean {
  return b.kind !== 'text' && b.kind !== 'calendar';
}

export function toUpsertMessage(b: Block): Record<string, unknown> {
  return {
    type: 'upsert_block',
    id: b.id,
    kind: b.kind,
    title: b.title,
    payload: b.payload,
    parent_id: b.parent_id,
    viewed_mode: b.viewed_mode,
    client_updated_at: b.updated_at,
    deleted: b.deleted,
    deleted_at: b.deleted_at,
  };
}

export function copyBlock(b: Block, patch: Partial<Block> & { clear_parent?: boolean; clear_deleted_at?: boolean }): Block {
  return {
    ...b,
    ...patch,
    parent_id: patch.clear_parent ? null : (patch.parent_id !== undefined ? patch.parent_id : b.parent_id),
    deleted_at: patch.clear_deleted_at ? null : (patch.deleted_at !== undefined ? patch.deleted_at : b.deleted_at),
    deleted_by: patch.clear_deleted_at ? null : (patch.deleted_by !== undefined ? patch.deleted_by : b.deleted_by),
    payload: patch.payload ? { ...patch.payload } : b.payload,
  };
}

export function newId(): string {
  return crypto.randomUUID();
}

export function nowMs(): number {
  return Date.now();
}

export const STICKY_COLORS = [
  { key: 'urgent', label: '紧急', tag: '紧急', color: '#ff453a', priority: 50 },
  { key: 'important', label: '重要', tag: '重要', color: '#ffd60a', priority: 40 },
  { key: 'todo', label: '待办', tag: '待办', color: '#0a84ff', priority: 30 },
  { key: 'idea', label: '灵感', tag: '灵感', color: '#bf5af2', priority: 20 },
  { key: 'memo', label: '备忘', tag: '备忘', color: '#30d158', priority: 10 },
  { key: 'default', label: '默认', tag: '', color: null as string | null, priority: 0 },
] as const;

export type StickyColorKey = (typeof STICKY_COLORS)[number]['key'];

export function stickyColorOf(b: Block) {
  const key = asString(b.payload.sticky_color, 'default');
  return STICKY_COLORS.find((c) => c.key === key) ?? STICKY_COLORS[STICKY_COLORS.length - 1]!;
}

export function blockPriority(b: Block): number {
  const explicit = b.payload.priority;
  if (typeof explicit === 'number' && Number.isFinite(explicit)) return explicit;
  return stickyColorOf(b).priority;
}

export function isCompleted(b: Block): boolean {
  return b.payload.completed === true;
}

export function shortTitle(text: string, max = 40): string {
  const first = text.trim().split('\n')[0] ?? '';
  const chars = [...first];
  return chars.length > max ? `${chars.slice(0, max).join('')}…` : first;
}

export const DOC_TYPES = [
  'paragraph',
  'heading1',
  'heading2',
  'heading3',
  'bullet',
  'numbered',
  'todo',
  'toggle',
  'quote',
  'code',
  'divider',
] as const;

export type DocType = (typeof DOC_TYPES)[number];

export function docTypeOf(b: Block): DocType {
  const t = asString(b.payload.type, 'paragraph');
  return (DOC_TYPES as readonly string[]).includes(t) ? (t as DocType) : 'paragraph';
}

export function orderOf(b: Block): number {
  const o = b.payload.order;
  if (typeof o === 'number' && Number.isFinite(o)) return o;
  return b.created_at;
}

export function docText(b: Block): string {
  return asString(b.payload.text);
}
