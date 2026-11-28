import { CHUNK_SIZE, HttpPending, openChunk, sealChunk } from '../crypto/seal';
import { concat, fromUtf8, u32be, utf8, readU32be } from '../crypto/bytes';
import { sha256 } from '@noble/hashes/sha2.js';
import { hex } from '../crypto/bytes';
import { serverPublic, type PinStore, ApiError } from './http';
import { endpoint } from '../protocol/url';

export const RESUME_THRESHOLD = 4 * 1024 * 1024;
export const DEFAULT_PART = 4 * 1024 * 1024;
export const MAX_FILE_BYTES = 4 * 1024 * 1024 * 1024;

export interface UploadResult {
  file_id: string;
  sha256: string;
  size: number;
}

export interface TransferHooks {
  onProgress?: (done: number, total: number) => void;
  isCanceled?: () => boolean;
  signal?: AbortSignal;
}

function hexSha(bytes: Uint8Array): string {
  return hex(sha256(bytes));
}

async function postBlob(server: string, body: Uint8Array, signal?: AbortSignal): Promise<Uint8Array> {
  let res: Response;
  try {
    res = await fetch(endpoint(server, '/api/blob'), {
      method: 'POST',
      headers: { 'content-type': 'application/octet-stream' },
      body: body as unknown as BodyInit,
      signal,
    });
  } catch (e) {
    if (e instanceof DOMException && e.name === 'AbortError') throw new ApiError('已取消');
    throw new ApiError(e instanceof Error ? e.message : '无法连接服务器');
  }
  const raw = new Uint8Array(await res.arrayBuffer());
  if (res.status === 413) {
    throw new ApiError('上传被拒绝：请求太大。Nginx 要设 client_max_body_size 0，Caddy 不要限制请求体。', 413);
  }
  if (res.status !== 200) {
    const msg = fromUtf8(raw).trim() || `上传失败（HTTP ${res.status}）`;
    throw new ApiError(msg, res.status);
  }
  return raw;
}

function frameHeader(envelope: Uint8Array, chunks: Uint8Array[]): Uint8Array {
  const parts = [u32be(envelope.length), envelope, ...chunks, u32be(0)];
  return concat(...parts);
}

function frameChunks(key: Uint8Array, data: Uint8Array): Uint8Array[] {
  const out: Uint8Array[] = [];
  let idx = 0;
  for (let i = 0; i < data.length; i += CHUNK_SIZE) {
    const n = Math.min(CHUNK_SIZE, data.length - i);
    const ct = sealChunk(key, idx++, data.subarray(i, i + n));
    out.push(u32be(ct.length), ct);
  }
  return out;
}

async function blobRpc(
  server: string,
  pub: Uint8Array,
  meta: Record<string, unknown>,
  data?: Uint8Array,
  hooks?: TransferHooks,
): Promise<Record<string, unknown>> {
  if (hooks?.isCanceled?.()) throw new ApiError('已取消');
  const pending = HttpPending.seal(pub, 3, '/api/blob', utf8('{}'), utf8(JSON.stringify(meta)));
  const chunks = data && data.length ? frameChunks(pending.chunkKey(), data) : [];
  const body = frameHeader(pending.envelope, chunks);
  const raw = await postBlob(server, body, hooks?.signal);
  const opened = pending.openResponse(raw);
  if (opened.status !== 200) {
    const msg = fromUtf8(opened.body).trim();
    if (msg.includes('未知操作')) throw new ApiError(msg, opened.status);
    throw new ApiError(msg || `上传失败 (${opened.status})`, opened.status);
  }
  if (!opened.body.length) return {};
  return JSON.parse(fromUtf8(opened.body)) as Record<string, unknown>;
}

export async function uploadFile(
  server: string,
  token: string,
  name: string,
  data: Uint8Array,
  hooks?: TransferHooks,
  pins?: PinStore,
): Promise<UploadResult> {
  if (data.length > MAX_FILE_BYTES) throw new ApiError('文件过大（上限 4 GB）');
  const pub = await serverPublic(server, pins);
  if (data.length > RESUME_THRESHOLD) return uploadResumable(server, token, name, data, pub, hooks);
  hooks?.onProgress?.(0, data.length);
  const meta = { op: 'put', name, size: data.length, token };
  const pending = HttpPending.seal(pub, 3, '/api/blob', utf8('{}'), utf8(JSON.stringify(meta)));
  const key = pending.chunkKey();
  const chunks = frameChunks(key, data);
  const body = frameHeader(pending.envelope, chunks);
  hooks?.onProgress?.(data.length > 0 ? data.length - 1 : 0, data.length);
  const raw = await postBlob(server, body, hooks?.signal);
  const opened = pending.openResponse(raw);
  if (opened.status !== 200) throw new ApiError(fromUtf8(opened.body).trim() || `上传失败 (${opened.status})`, opened.status);
  const j = JSON.parse(fromUtf8(opened.body)) as Record<string, unknown>;
  const fileId = String(j.file_id ?? j.id ?? '');
  if (!fileId) throw new ApiError('服务器没有返回文件 id');
  hooks?.onProgress?.(data.length, data.length);
  return { file_id: fileId, sha256: String(j.sha256 ?? hexSha(data)), size: Number(j.size ?? data.length) };
}

async function uploadResumable(
  server: string,
  token: string,
  name: string,
  data: Uint8Array,
  pub: Uint8Array,
  hooks?: TransferHooks,
): Promise<UploadResult> {
  const init = await blobRpc(server, pub, { op: 'put_init', name, size: data.length, token }, undefined, hooks);
  const uploadId = String(init.upload_id ?? '');
  if (!uploadId) throw new ApiError('服务器没有返回 upload_id');
  const serverPart = typeof init.part_size === 'number' ? init.part_size : DEFAULT_PART;
  const partSize = Math.min(8 * 1024 * 1024, Math.max(1024 * 1024, serverPart));
  let offset = 0;
  try {
    while (offset < data.length) {
      if (hooks?.isCanceled?.()) throw new ApiError('已取消');
      const want = Math.min(partSize, data.length - offset);
      const part = data.subarray(offset, offset + want);
      let attempt = 0;
      let next = offset;
      // eslint-disable-next-line no-constant-condition
      while (true) {
        try {
          const r = await blobRpc(
            server,
            pub,
            { op: 'put_part', upload_id: uploadId, offset, length: part.length, token },
            part,
            {
              ...hooks,
              onProgress: (done, _total) => hooks?.onProgress?.(offset + done, data.length),
            },
          );
          next = typeof r.offset === 'number' ? r.offset : offset + part.length;
          break;
        } catch (e) {
          attempt += 1;
          if (attempt >= 5 || (e instanceof ApiError && (e.status === 401 || e.status === 413))) throw e;
          await new Promise((r) => setTimeout(r, attempt * 1000));
        }
      }
      offset = next;
      hooks?.onProgress?.(Math.min(offset, data.length - (offset < data.length ? 1 : 0)), data.length);
    }
    const fin = await blobRpc(server, pub, { op: 'put_finish', upload_id: uploadId, token, sha256: hexSha(data) }, undefined, hooks);
    const fileId = String(fin.file_id ?? fin.id ?? '');
    if (!fileId) throw new ApiError('服务器没有返回文件 id');
    hooks?.onProgress?.(data.length, data.length);
    return { file_id: fileId, sha256: String(fin.sha256 ?? hexSha(data)), size: Number(fin.size ?? data.length) };
  } catch (e) {
    try {
      await blobRpc(server, pub, { op: 'put_abort', upload_id: uploadId, token });
    } catch {
      /* ignore */
    }
    throw e;
  }
}

class ByteReader {
  private buf = new Uint8Array(0);
  constructor(private readonly chunks: AsyncIterator<Uint8Array>) {}

  private async need(n: number): Promise<void> {
    while (this.buf.length < n) {
      const nxt = await this.chunks.next();
      if (nxt.done) throw new ApiError('下载失败：连接被关掉了。');
      const c = nxt.value;
      const nb = new Uint8Array(this.buf.length + c.length);
      nb.set(this.buf);
      nb.set(c, this.buf.length);
      this.buf = nb;
    }
  }

  async u32(): Promise<number> {
    await this.need(4);
    const n = readU32be(this.buf, 0);
    this.buf = this.buf.subarray(4);
    return n;
  }

  async take(n: number): Promise<Uint8Array> {
    await this.need(n);
    const out = this.buf.subarray(0, n);
    this.buf = this.buf.subarray(n);
    return out;
  }

  async rest(): Promise<Uint8Array> {
    const parts: Uint8Array[] = [this.buf];
    this.buf = new Uint8Array(0);
    while (true) {
      const nxt = await this.chunks.next();
      if (nxt.done) break;
      if (nxt.value.length) parts.push(nxt.value);
    }
    return concat(...parts);
  }
}

async function* streamBody(res: Response): AsyncGenerator<Uint8Array> {
  if (!res.body) {
    yield new Uint8Array(await res.arrayBuffer());
    return;
  }
  const reader = res.body.getReader();
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) return;
      if (value && value.length) yield value;
    }
  } finally {
    reader.releaseLock();
  }
}

export async function downloadFile(
  server: string,
  token: string,
  fileId: string,
  hooks?: TransferHooks,
  pins?: PinStore,
  expectSize = 0,
): Promise<Uint8Array> {
  const pub = await serverPublic(server, pins);
  const parts: Uint8Array[] = [];
  let total = 0;
  await downloadStream(server, token, fileId, pub, (chunk) => {
    parts.push(chunk);
    total += chunk.length;
    hooks?.onProgress?.(total, expectSize || total);
  }, hooks);
  const out = new Uint8Array(total);
  let o = 0;
  for (const p of parts) {
    out.set(p, o);
    o += p.length;
  }
  return out;
}

export async function downloadStream(
  server: string,
  token: string,
  fileId: string,
  pub: Uint8Array,
  onChunk: (plain: Uint8Array) => void,
  hooks?: TransferHooks,
): Promise<void> {
  const meta = { op: 'get', file_id: fileId, token };
  const pending = HttpPending.seal(pub, 3, '/api/blob', utf8('{}'), utf8(JSON.stringify(meta)));
  const body = frameHeader(pending.envelope, []);
  let res: Response;
  try {
    res = await fetch(endpoint(server, '/api/blob'), {
      method: 'POST',
      headers: { 'content-type': 'application/octet-stream' },
      body: body as unknown as BodyInit,
      signal: hooks?.signal,
    });
  } catch (e) {
    if (e instanceof DOMException && e.name === 'AbortError') throw new ApiError('已取消');
    throw new ApiError(e instanceof Error ? e.message : '下载失败');
  }
  if (res.status !== 200) {
    const raw = new Uint8Array(await res.arrayBuffer());
    throw new ApiError(fromUtf8(raw).trim() || `下载失败（HTTP ${res.status}）`, res.status);
  }
  // Response is: sealed header (u32 + envelope) then chunk frames, OR a single sealed envelope
  // matching openResponse of the whole body for errors. The official client reads:
  // u32 header_len, header envelope (status+maybe meta), then u32+chunk... until 0.
  const reader = new ByteReader(streamBody(res)[Symbol.asyncIterator]());
  const first = await reader.u32();
  // Error replies are a bare SNC1 envelope (magic 0x534E4331), not length-prefixed.
  if (first === 0x534e4331) {
    const rest = await reader.rest();
    const env = concat(u32be(first), rest);
    const opened = pending.openResponse(env);
    throw new ApiError(fromUtf8(opened.body).trim() || `下载失败 (${opened.status})`, opened.status);
  }
  if (first === 0 || first > 256 * 1024) throw new ApiError('下载响应无效');
  const header = await reader.take(first);
  const opened = pending.openResponse(header);
  if (opened.status !== 200) throw new ApiError(fromUtf8(opened.body).trim() || `下载失败 (${opened.status})`, opened.status);
  const key = pending.chunkKey();
  let idx = 0;
  while (true) {
    if (hooks?.isCanceled?.()) throw new ApiError('已取消');
    const n = await reader.u32();
    if (n === 0) break;
    if (n > 1024 * 1024 + 32) throw new ApiError('下载分片过大');
    const ct = await reader.take(n);
    onChunk(openChunk(key, idx++, ct));
  }
}
