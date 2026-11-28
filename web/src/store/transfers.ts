import { downloadFile, uploadFile } from '../api/blob';
import { ApiError, type PinStore } from '../api/http';

export type TransferKind = 'upload' | 'download';
export type TransferStatus = 'queued' | 'running' | 'done' | 'error' | 'canceled';

export interface TransferItem {
  id: string;
  kind: TransferKind;
  name: string;
  done: number;
  total: number;
  status: TransferStatus;
  error?: string;
  startedAt: number;
  updatedAt: number;
  speed: number;
  fileId?: string;
  sha256?: string;
}

type Listener = () => void;

export class TransferQueue {
  items: TransferItem[] = [];
  private listeners = new Set<Listener>();
  private runningUp = 0;
  private runningDown = 0;
  private waiters: Array<() => void> = [];

  constructor(
    private readonly maxUp = 1,
    private readonly maxDown = 2,
  ) {}

  subscribe(fn: Listener): () => void {
    this.listeners.add(fn);
    return () => this.listeners.delete(fn);
  }

  get active(): TransferItem[] {
    return this.items.filter((t) => t.status === 'running' || t.status === 'queued');
  }

  async upload(
    server: string,
    token: string,
    name: string,
    data: Uint8Array,
    pins?: PinStore,
  ): Promise<{ file_id: string; sha256: string; size: number }> {
    const item = this.add('upload', name, data.length);
    await this.slot('upload');
    if (item.status === 'canceled') throw new ApiError('已取消');
    if (item.status !== 'queued') throw new ApiError('已取消');
    item.status = 'running';
    this.bump();
    const ac = new AbortController();
    const unsub = this.watchCancel(item.id, () => ac.abort());
    try {
      const r = await uploadFile(server, token, name, data, {
        signal: ac.signal,
        isCanceled: () => item.status === 'canceled',
        onProgress: (done, total) => this.progress(item, done, total),
      }, pins);
      item.fileId = r.file_id;
      item.sha256 = r.sha256;
      item.status = 'done';
      item.done = r.size;
      item.total = r.size;
      this.bump();
      return r;
    } catch (e) {
      if (item.status === 'running') {
        item.status = 'error';
        item.error = e instanceof Error ? e.message : String(e);
        this.bump();
      }
      throw e;
    } finally {
      unsub();
      this.runningUp = Math.max(0, this.runningUp - 1);
      this.release();
    }
  }

  async download(
    server: string,
    token: string,
    name: string,
    fileId: string,
    total: number,
    pins?: PinStore,
  ): Promise<Uint8Array> {
    const item = this.add('download', name, total);
    await this.slot('download');
    if (item.status === 'canceled') throw new ApiError('已取消');
    if (item.status !== 'queued') throw new ApiError('已取消');
    item.status = 'running';
    this.bump();
    const ac = new AbortController();
    const unsub = this.watchCancel(item.id, () => ac.abort());
    try {
      const data = await downloadFile(server, token, fileId, {
        signal: ac.signal,
        isCanceled: () => item.status === 'canceled',
        onProgress: (done, t) => this.progress(item, done, t || total),
      }, pins, total);
      item.status = 'done';
      item.done = data.length;
      item.total = data.length;
      this.bump();
      return data;
    } catch (e) {
      if (item.status === 'running') {
        item.status = 'error';
        item.error = e instanceof Error ? e.message : String(e);
        this.bump();
      }
      throw e;
    } finally {
      unsub();
      this.runningDown = Math.max(0, this.runningDown - 1);
      this.release();
    }
  }

  cancel(id: string): void {
    const it = this.items.find((t) => t.id === id);
    if (!it || it.status === 'done') return;
    it.status = 'canceled';
    this.bump();
    this.release();
  }

  clearFinished(): void {
    this.items = this.items.filter((t) => t.status === 'running' || t.status === 'queued');
    this.bump();
  }

  private add(kind: TransferKind, name: string, total: number): TransferItem {
    const item: TransferItem = {
      id: crypto.randomUUID(),
      kind,
      name,
      done: 0,
      total,
      status: 'queued',
      startedAt: Date.now(),
      updatedAt: Date.now(),
      speed: 0,
    };
    this.items = [item, ...this.items].slice(0, 40);
    this.bump();
    return item;
  }

  private progress(item: TransferItem, done: number, total: number): void {
    const now = Date.now();
    const dt = Math.max(1, now - item.updatedAt);
    const delta = Math.max(0, done - item.done);
    item.speed = delta / (dt / 1000);
    item.done = done;
    item.total = total || item.total;
    item.updatedAt = now;
    this.bump();
  }

  private slot(kind: TransferKind): Promise<void> {
    const ready = () => (kind === 'upload' ? this.runningUp < this.maxUp : this.runningDown < this.maxDown);
    if (ready()) {
      if (kind === 'upload') this.runningUp += 1;
      else this.runningDown += 1;
      return Promise.resolve();
    }
    return new Promise((resolve) => {
      const tryIt = () => {
        if (!ready()) return false;
        if (kind === 'upload') this.runningUp += 1;
        else this.runningDown += 1;
        resolve();
        return true;
      };
      this.waiters.push(() => {
        tryIt();
      });
    });
  }

  private release(): void {
    const next = [...this.waiters];
    this.waiters = [];
    for (const w of next) w();
  }

  private watchCancel(id: string, abort: () => void): () => void {
    const timer = setInterval(() => {
      const it = this.items.find((t) => t.id === id);
      if (it?.status === 'canceled') abort();
    }, 200);
    return () => clearInterval(timer);
  }

  private bump(): void {
    for (const fn of this.listeners) fn();
  }
}

export function formatSize(n: number): string {
  if (n < 1024) return `${n} B`;
  if (n < 1024 * 1024) return `${(n / 1024).toFixed(1)} KB`;
  if (n < 1024 * 1024 * 1024) return `${(n / 1024 / 1024).toFixed(1)} MB`;
  return `${(n / 1024 / 1024 / 1024).toFixed(2)} GB`;
}

export function formatSpeed(n: number): string {
  if (!n) return '0 B/s';
  return `${formatSize(Math.round(n))}/s`;
}
