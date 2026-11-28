import { ClientHello, type WsPair, SealError } from '../crypto/seal';
import { fromUtf8, utf8 } from '../crypto/bytes';
import {
  type Block,
  type ConnState,
  type ViewedMode,
  type BlockKind,
  blockFromServer,
  copyBlock,
  inTrash,
  isInboxItem,
  isViewed,
  newId,
  nowMs,
  toUpsertMessage,
} from '../protocol/types';
import { wsUrl } from '../protocol/url';
import { serverPublic, type PinStore } from '../api/http';

export interface SyncPersist {
  load(): { blocks: Block[]; outbox: Record<string, unknown>[]; lastSeq: number } | null;
  save(data: { blocks: Block[]; outbox: Record<string, unknown>[]; lastSeq: number }): void;
}

export type SyncListener = () => void;

export class SyncEngine {
  private blocks = new Map<string, Block>();
  private outbox: Record<string, unknown>[] = [];
  private lastSeq = 0;
  private state: ConnState = 'offline';
  private serverUrl: string | null = null;
  private token: string | null = null;
  private ws: WebSocket | null = null;
  private pair: WsPair | null = null;
  private sendQ: Promise<void> = Promise.resolve();
  private wantConnected = false;
  private catchingUp = false;
  private attempt = 0;
  private epoch = 0;
  private disposed = false;
  private reconnectTimer: ReturnType<typeof setTimeout> | null = null;
  private pingTimer: ReturnType<typeof setInterval> | null = null;
  private listeners = new Set<SyncListener>();
  lastError: string | null = null;
  sealBlocked = false;
  trashRetentionDays = 30;
  onRemoteNew?: (block: Block) => void;

  constructor(
    readonly deviceId: string,
    private readonly persist?: SyncPersist,
    private readonly pins?: PinStore,
    private readonly maxBackoffMs = 30_000,
    private readonly pingIntervalMs = 8_000,
  ) {
    const saved = persist?.load();
    if (saved) {
      for (const b of saved.blocks) this.blocks.set(b.id, b);
      this.outbox = saved.outbox;
      this.lastSeq = saved.lastSeq;
    }
  }

  subscribe(fn: SyncListener): () => void {
    this.listeners.add(fn);
    return () => this.listeners.delete(fn);
  }

  get connState(): ConnState {
    return this.state;
  }
  get pendingCount(): number {
    return this.outbox.length;
  }
  get latestSeq(): number {
    return this.lastSeq;
  }

  all(): Block[] {
    return [...this.blocks.values()];
  }

  /** 只读的全部块（含回收站），按 id 索引；任务进度计算用。 */
  blockMap(): ReadonlyMap<string, Block> {
    return this.blocks;
  }

  visible(): Block[] {
    return this.all()
      .filter((b) => !b.deleted && !this.isHidden(b))
      .sort((a, b) => b.updated_at - a.updated_at);
  }

  childrenOf(parentId: string | null): Block[] {
    const vis = this.visible();
    if (parentId != null) return vis.filter((b) => b.parent_id === parentId && isInboxItem(b));
    return vis.filter((b) => {
      if (!isInboxItem(b)) return false;
      if (b.parent_id == null) return true;
      const p = this.blocks.get(b.parent_id);
      return !p || p.deleted;
    });
  }

  byId(id: string): Block | undefined {
    return this.blocks.get(id);
  }

  isHidden(b: Block): boolean {
    let cur = b;
    const seen = new Set<string>();
    for (;;) {
      if (cur.deleted || cur.deleted_at != null) return true;
      const pid = cur.parent_id;
      if (pid == null || !seen.add(pid)) return false;
      const p = this.blocks.get(pid);
      if (!p) return false;
      cur = p;
    }
  }

  get trash(): Block[] {
    return this.all()
      .filter((b) => inTrash(b) && b.kind !== 'text')
      .sort((a, b) => (b.deleted_at ?? 0) - (a.deleted_at ?? 0));
  }

  descendantIds(id: string, includeTrashed = false): string[] {
    const out: string[] = [];
    const walk = (pid: string) => {
      for (const b of this.blocks.values()) {
        if (b.parent_id !== pid) continue;
        if (!includeTrashed && (b.deleted || b.deleted_at != null)) continue;
        if (b.deleted && !includeTrashed) continue;
        out.push(b.id);
        walk(b.id);
      }
    };
    walk(id);
    return out;
  }

  trashChildCount(id: string): number {
    return this.descendantIds(id, true).filter((d) => this.blocks.get(d)?.kind !== 'text').length;
  }

  connect(server: string, token: string): void {
    this.serverUrl = server;
    this.token = token;
    this.wantConnected = true;
    this.sealBlocked = false;
    this.attempt = 0;
    this.epoch += 1;
    void this.open();
  }

  disconnect(): void {
    this.wantConnected = false;
    this.epoch += 1;
    this.closeSocket();
    this.setState('offline');
  }

  dispose(): void {
    this.disposed = true;
    this.disconnect();
    this.listeners.clear();
  }

  create(opts: {
    kind: BlockKind;
    title: string;
    payload?: Record<string, unknown>;
    parentId?: string | null;
    viewedMode?: ViewedMode;
    id?: string;
  }): Block {
    const now = nowMs();
    const b: Block = {
      id: opts.id ?? newId(),
      kind: opts.kind,
      title: opts.title,
      payload: { ...(opts.payload ?? {}) },
      parent_id: opts.parentId ?? null,
      viewed_mode: opts.viewedMode ?? 'per_device',
      viewed_global: false,
      created_at: now,
      updated_at: now,
      created_by: this.deviceId,
      deleted: false,
      deleted_at: null,
      deleted_by: null,
      seq: 0,
      viewed_local: true,
      pending: true,
    };
    this.blocks.set(b.id, b);
    this.enqueue(toUpsertMessage(b));
    this.notify();
    return b;
  }

  update(
    id: string,
    patch: {
      title?: string;
      payload?: Record<string, unknown>;
      viewedMode?: ViewedMode;
      parentId?: string | null;
      moveToRoot?: boolean;
    },
  ): Block | undefined {
    const old = this.blocks.get(id);
    if (!old) return undefined;
    if (patch.parentId && (patch.parentId === id || this.descendantIds(id).includes(patch.parentId))) return old;
    const b = copyBlock(old, {
      title: patch.title ?? old.title,
      payload: patch.payload ?? old.payload,
      viewed_mode: patch.viewedMode ?? old.viewed_mode,
      parent_id: patch.parentId,
      clear_parent: patch.moveToRoot,
      updated_at: Math.max(nowMs(), old.updated_at + 1),
      pending: true,
    });
    this.blocks.set(id, b);
    this.enqueue(toUpsertMessage(b));
    this.notify();
    return b;
  }

  setViewed(id: string, viewed: boolean): void {
    const b = this.blocks.get(id);
    if (!b || isViewed(b) === viewed) return;
    this.blocks.set(
      id,
      b.viewed_mode === 'global' ? copyBlock(b, { viewed_global: viewed }) : copyBlock(b, { viewed_local: viewed }),
    );
    this.enqueue({ type: 'set_viewed', block_id: id, viewed });
    this.notify();
  }

  delete(id: string): string[] {
    const old = this.blocks.get(id);
    if (!old || old.deleted || old.deleted_at != null) return [];
    const now = nowMs();
    const b = copyBlock(old, {
      deleted_at: now,
      deleted_by: this.deviceId,
      updated_at: Math.max(now, old.updated_at + 1),
      pending: true,
    });
    this.blocks.set(id, b);
    this.enqueue(toUpsertMessage(b));
    this.notify();
    return [id];
  }

  restoreAll(ids: string[]): string[] {
    const toRoot: string[] = [];
    for (const id of ids) {
      const old = this.blocks.get(id);
      if (!old || old.deleted || old.deleted_at == null) continue;
      const pid = old.parent_id;
      const parent = pid ? this.blocks.get(pid) : undefined;
      const orphan = !!pid && (!parent || this.isHidden(parent)) && !ids.includes(pid);
      if (orphan) toRoot.push(id);
      const b = copyBlock(old, {
        clear_deleted_at: true,
        clear_parent: orphan,
        updated_at: Math.max(nowMs(), old.updated_at + 1),
        pending: true,
      });
      this.blocks.set(id, b);
      this.enqueue(toUpsertMessage(b));
    }
    this.notify();
    return toRoot;
  }

  purge(ids: string[]): void {
    for (const id of ids) {
      for (const d of [...this.descendantIds(id, true), id]) {
        const old = this.blocks.get(d);
        if (!old || old.deleted) continue;
        const b = copyBlock(old, { deleted: true, updated_at: Math.max(nowMs(), old.updated_at + 1), pending: true });
        this.blocks.set(d, b);
        this.enqueue(toUpsertMessage(b));
      }
    }
    this.notify();
  }

  emptyTrash(): void {
    this.purge(this.trash.map((b) => b.id));
  }

  /** 本次运行生成的冲突副本数。 */
  conflictCopies = 0;

  /**
   * 本地未同步的修改被另一台设备更晚的版本覆盖（LWW）时，先把本地版本另存为同级「冲突副本」，
   * 不悄悄丢数据。与 App 端 `SyncClient._keepConflictCopy` 行为一致。
   */
  private keepConflictCopy(local: Block | undefined, incoming: Block): void {
    if (!local || !local.pending || local.deleted || local.deleted_at != null) return;
    if (incoming.deleted || incoming.deleted_at != null) return;
    if (local.updated_at > incoming.updated_at) return;
    if (local.kind === 'folder') return;
    if (local.title === incoming.title && JSON.stringify(sortKeys(local.payload)) === JSON.stringify(sortKeys(incoming.payload))) return;
    const pendingOp = this.outbox.some((o) => o.type === 'upsert_block' && o.id === local.id && Number(o.client_updated_at) === local.updated_at);
    if (!pendingOp) return;
    const now = nowMs();
    const copy: Block = {
      ...local,
      id: newId(),
      title: conflictTitle(local.title, new Date(local.updated_at)),
      payload: { ...local.payload },
      created_at: now,
      updated_at: now,
      created_by: this.deviceId,
      seq: 0,
      viewed_local: false,
      pending: true,
    };
    this.blocks.set(copy.id, copy);
    this.enqueue(toUpsertMessage(copy));
    this.conflictCopies++;
  }

  applyServerMessage(msg: Record<string, unknown>): void {
    const type = msg.type;
    if (type === 'auth_ok') {
      this.setState('online');
      this.attempt = 0;
      this.catchingUp = true;
      this.send({ type: 'sync_since', since_seq: this.lastSeq });
    } else if (type === 'auth_error') {
      this.lastError = String(msg.message ?? '登录已失效，请重新登录');
      this.setState('authError');
      this.wantConnected = false;
      this.closeSocket();
    } else if (type === 'block_update') {
      const raw = msg.block;
      if (!raw || typeof raw !== 'object') return;
      const incoming = blockFromServer(raw as Record<string, unknown>);
      const local = this.blocks.get(incoming.id);
      const viewedLocal = local?.viewed_local ?? false;
      if (local && local.pending && local.updated_at > incoming.updated_at) {
        // LWW: keep the newer local edit; the outbox will replay it.
        return;
      }
      this.keepConflictCopy(local, incoming);
      // 首次登录 / 重连追平历史时不弹「新内容」提示，只提示实时到达的新内容。
      const isNew = !this.catchingUp && !local && !incoming.deleted && incoming.deleted_at == null && incoming.created_by !== this.deviceId;
      this.blocks.set(incoming.id, { ...incoming, viewed_local: viewedLocal, pending: false });
      if (incoming.seq > this.lastSeq) this.lastSeq = incoming.seq;
      this.outbox = this.outbox.filter((o) => !(o.type === 'upsert_block' && o.id === incoming.id && Number(o.client_updated_at) <= incoming.updated_at));
      if (isNew) this.onRemoteNew?.(incoming);
    } else if (type === 'viewed_update') {
      const id = String(msg.block_id ?? '');
      const b = this.blocks.get(id);
      if (!b) return;
      const viewed = msg.viewed === true;
      if (msg.device_id == null) this.blocks.set(id, copyBlock(b, { viewed_global: viewed }));
      else if (msg.device_id === this.deviceId) this.blocks.set(id, copyBlock(b, { viewed_local: viewed }));
      const seq = Number(msg.seq ?? 0);
      if (seq > this.lastSeq) this.lastSeq = seq;
      this.outbox = this.outbox.filter((o) => !(o.type === 'set_viewed' && o.block_id === id));
    } else if (type === 'sync_complete') {
      const latest = Number(msg.latest_seq ?? this.lastSeq);
      if (latest > this.lastSeq) this.lastSeq = latest;
      this.catchingUp = false;
      this.flushOutbox();
    } else if (type === 'error') {
      this.lastError = String(msg.message ?? '同步错误');
    } else if (type === 'pong') {
      // keep-alive
    }
    this.save();
    this.notify();
  }

  /** Test helper: pretend the socket is online so outbox can be inspected / flushed. */
  markOnlineForTests(): void {
    this.state = 'online';
    this.catchingUp = false;
  }

  private enqueue(op: Record<string, unknown>): void {
    if (op.type === 'upsert_block') {
      this.outbox = this.outbox.filter((o) => !(o.type === 'upsert_block' && o.id === op.id));
    } else if (op.type === 'set_viewed') {
      this.outbox = this.outbox.filter((o) => !(o.type === 'set_viewed' && o.block_id === op.block_id));
    }
    this.outbox.push(op);
    if (this.state === 'online' && !this.catchingUp) this.send(op);
    this.save();
  }

  private flushOutbox(): void {
    if (this.state !== 'online' || this.catchingUp) return;
    for (const o of this.outbox) this.send(o);
  }

  private send(obj: Record<string, unknown>): void {
    const pair = this.pair;
    const ws = this.ws;
    if (!pair || !ws || ws.readyState !== WebSocket.OPEN) return;
    const payload = utf8(JSON.stringify(obj));
    this.sendQ = this.sendQ.then(() => {
      if (this.ws !== ws || this.ws.readyState !== WebSocket.OPEN) return;
      this.ws.send(pair.send.seal(payload) as unknown as ArrayBuffer);
    });
  }

  private async open(): Promise<void> {
    if (!this.wantConnected || !this.serverUrl || !this.token || this.disposed) return;
    const epoch = this.epoch;
    this.setState('connecting');
    this.lastError = null;
    try {
      const pub = await serverPublic(this.serverUrl, this.pins);
      if (epoch !== this.epoch) return;
      const hello = new ClientHello();
      const url = wsUrl(this.serverUrl);
      await new Promise<void>((resolve, reject) => {
        const socket = new WebSocket(url);
        socket.binaryType = 'arraybuffer';
        this.ws = socket;
        let settled = false;
        const fail = (e: Error) => {
          if (settled) return;
          settled = true;
          reject(e);
        };
        socket.onopen = () => {
          socket.send(hello.frame as unknown as ArrayBuffer);
        };
        socket.onerror = () => fail(new Error('WebSocket 连接失败'));
        socket.onclose = () => {
          if (!settled) fail(new Error('连接已关闭'));
          if (this.ws === socket) this.onClosed(epoch);
        };
        socket.onmessage = (ev) => {
          if (!settled) {
            try {
              const data = toBytes(ev.data);
              this.pair = hello.finish(pub, data);
              settled = true;
              socket.onmessage = (m) => void this.onFrame(toBytes(m.data));
              this.send({ type: 'auth', token: this.token, device_id: this.deviceId });
              this.startPing();
              resolve();
            } catch (e) {
              fail(e instanceof Error ? e : new Error(String(e)));
            }
            return;
          }
        };
      });
    } catch (e) {
      if (epoch !== this.epoch) return;
      if (e instanceof SealError && e.fatal) {
        this.sealBlocked = true;
        this.lastError = e.message;
        this.wantConnected = false;
        this.setState('authError');
        this.closeSocket();
        this.notify();
        return;
      }
      this.lastError = e instanceof Error ? e.message : String(e);
      this.scheduleReconnect();
    }
  }

  private async onFrame(data: Uint8Array): Promise<void> {
    const pair = this.pair;
    if (!pair) return;
    try {
      const plain = pair.recv.open(data);
      const msg = JSON.parse(fromUtf8(plain)) as Record<string, unknown>;
      this.applyServerMessage(msg);
    } catch (e) {
      this.lastError = e instanceof Error ? e.message : '无法解密同步帧';
      this.closeSocket();
      this.scheduleReconnect();
    }
  }

  private startPing(): void {
    if (this.pingTimer) clearInterval(this.pingTimer);
    this.pingTimer = setInterval(() => {
      if (this.state === 'online') this.send({ type: 'ping' });
    }, this.pingIntervalMs);
  }

  private onClosed(epoch: number): void {
    if (epoch !== this.epoch) return;
    this.closeSocket();
    if (this.wantConnected && !this.sealBlocked && this.state !== 'authError') this.scheduleReconnect();
    else if (this.state !== 'authError') this.setState('offline');
  }

  private scheduleReconnect(): void {
    this.setState('offline');
    if (!this.wantConnected || this.sealBlocked) return;
    if (this.reconnectTimer) clearTimeout(this.reconnectTimer);
    const delay = Math.min(this.maxBackoffMs, 1000 * 2 ** Math.min(this.attempt, 5));
    this.attempt += 1;
    this.reconnectTimer = setTimeout(() => {
      this.epoch += 1;
      void this.open();
    }, delay);
  }

  private closeSocket(): void {
    if (this.pingTimer) {
      clearInterval(this.pingTimer);
      this.pingTimer = null;
    }
    if (this.reconnectTimer) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = null;
    }
    const ws = this.ws;
    this.ws = null;
    this.pair = null;
    if (ws) {
      ws.onopen = null;
      ws.onmessage = null;
      ws.onerror = null;
      ws.onclose = null;
      try {
        ws.close();
      } catch {
        /* ignore */
      }
    }
  }

  private setState(s: ConnState): void {
    if (this.state === s) return;
    this.state = s;
    this.notify();
  }

  private save(): void {
    this.persist?.save({
      blocks: [...this.blocks.values()],
      outbox: this.outbox,
      lastSeq: this.lastSeq,
    });
  }

  private notify(): void {
    if (this.disposed) return;
    for (const fn of this.listeners) fn();
  }
}

function toBytes(data: unknown): Uint8Array {
  if (data instanceof ArrayBuffer) return new Uint8Array(data);
  if (data instanceof Uint8Array) return data;
  if (typeof Blob !== 'undefined' && data instanceof Blob) {
    throw new SealError('unexpected blob frame');
  }
  if (typeof data === 'string') return utf8(data);
  throw new SealError('未知的套接字帧');
}

function sortKeys(v: unknown): unknown {
  if (Array.isArray(v)) return v.map(sortKeys);
  if (v && typeof v === 'object') {
    const o = v as Record<string, unknown>;
    return Object.fromEntries(Object.keys(o).sort().map((k) => [k, sortKeys(o[k])]));
  }
  return v;
}

export function conflictTitle(title: string, at: Date): string {
  const two = (n: number) => String(n).padStart(2, '0');
  const stamp = `${at.getMonth() + 1}/${at.getDate()} ${two(at.getHours())}:${two(at.getMinutes())}`;
  return `${title.trim() ? title : '无标题'}（冲突副本 ${stamp}）`;
}
