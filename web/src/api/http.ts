import { fingerprint, HttpPending, parsePubB64, SealError, SealPinMismatch } from '../crypto/seal';
import { fromUtf8, utf8 } from '../crypto/bytes';
import type { AuthResponse, HealthResponse } from '../protocol/types';
import { endpoint } from '../protocol/url';

export class ApiError extends Error {
  status?: number;
  constructor(message: string, status?: number) {
    super(message);
    this.name = 'ApiError';
    this.status = status;
  }
}

export interface PinStore {
  get(server: string): string | undefined;
  set(server: string, hex: string): void;
  clear(server: string): void;
}

const pubCache = new Map<string, Uint8Array>();

export function forgetServerPub(server: string): void {
  pubCache.delete(server);
}

export async function fetchHealth(server: string, timeoutMs = 8000): Promise<HealthResponse> {
  const ctrl = new AbortController();
  const t = setTimeout(() => ctrl.abort(), timeoutMs);
  try {
    const res = await fetch(endpoint(server, '/health'), { signal: ctrl.signal });
    if (!res.ok) throw new ApiError(`服务器无响应 (${res.status})`, res.status);
    return (await res.json()) as HealthResponse;
  } catch (e) {
    if (e instanceof ApiError) throw e;
    if (e instanceof DOMException && e.name === 'AbortError') throw new ApiError('连接超时，服务器没有回复。');
    throw new ApiError(e instanceof Error ? e.message : '无法连接服务器');
  } finally {
    clearTimeout(t);
  }
}

export async function serverPublic(server: string, pins?: PinStore): Promise<Uint8Array> {
  const cached = pubCache.get(server);
  if (cached) return cached;
  const health = await fetchHealth(server);
  if (!health.seal_pub) throw new SealError('服务器过旧，没有加密通道，请升级服务器', true);
  const pub = parsePubB64(health.seal_pub);
  const hex = fingerprint(pub);
  const saved = pins?.get(server);
  if (!saved) {
    pins?.set(server, hex);
  } else if (saved !== hex) {
    throw new SealPinMismatch(saved, hex);
  }
  pubCache.set(server, pub);
  return pub;
}

export async function sealedPost(
  server: string,
  path: string,
  body: unknown,
  opts?: { token?: string; pins?: PinStore; pub?: Uint8Array },
): Promise<{ status: number; body: Uint8Array }> {
  const pub = opts?.pub ?? (await serverPublic(server, opts?.pins));
  const headers = opts?.token ? utf8(JSON.stringify({ authorization: `Bearer ${opts.token}` })) : utf8('{}');
  const pending = HttpPending.seal(pub, 1, path, headers, utf8(JSON.stringify(body)));
  let res: Response;
  try {
    res = await fetch(endpoint(server, '/api/seal'), {
      method: 'POST',
      headers: { 'content-type': 'application/octet-stream' },
      body: pending.envelope as unknown as BodyInit,
    });
  } catch (e) {
    throw new ApiError(e instanceof Error ? e.message : '无法连接服务器');
  }
  const raw = new Uint8Array(await res.arrayBuffer());
  if (res.status !== 200) {
    const msg = safeText(raw) || `加密通道无效 (${res.status})`;
    throw new ApiError(msg, res.status);
  }
  return pending.openResponse(raw);
}

function safeText(b: Uint8Array): string {
  try {
    return fromUtf8(b);
  } catch {
    return '';
  }
}

function decodeJson(body: Uint8Array): Record<string, unknown> {
  if (!body.length) return {};
  return JSON.parse(fromUtf8(body)) as Record<string, unknown>;
}

function throwStatus(status: number, body: Uint8Array): never {
  const msg = safeText(body).trim() || `请求失败 (${status})`;
  throw new ApiError(msg, status);
}

async function authCall(server: string, path: string, body: unknown, pins?: PinStore, token?: string): Promise<AuthResponse> {
  const { status, body: raw } = await sealedPost(server, path, body, { pins, token });
  if (status !== 200) throwStatus(status, raw);
  return decodeJson(raw) as unknown as AuthResponse;
}

export async function login(
  server: string,
  username: string,
  password: string,
  deviceId: string,
  deviceName?: string,
  pins?: PinStore,
): Promise<AuthResponse> {
  return authCall(server, '/api/login', { username, password, device_id: deviceId, device_name: deviceName ?? '网页版' }, pins);
}

export async function register(server: string, username: string, password: string, pins?: PinStore): Promise<AuthResponse> {
  return authCall(server, '/api/register', { username, password }, pins);
}

export async function recover(
  server: string,
  username: string,
  recoveryCode: string,
  newPassword: string,
  deviceId: string,
  deviceName?: string,
  pins?: PinStore,
): Promise<AuthResponse> {
  return authCall(
    server,
    '/api/recover',
    {
      username,
      recovery_code: recoveryCode,
      new_password: newPassword,
      device_id: deviceId,
      device_name: deviceName ?? '网页版',
    },
    pins,
  );
}

export async function regenerateRecoveryCode(server: string, token: string, password: string, pins?: PinStore): Promise<string> {
  const { status, body } = await sealedPost(server, '/api/recovery-code', { password }, { token, pins });
  if (status !== 200) throwStatus(status, body);
  const j = decodeJson(body);
  const code = j.recovery_code;
  if (typeof code !== 'string') throw new ApiError('服务器没有返回恢复码');
  return code;
}

export async function changePassword(server: string, token: string, oldPassword: string, newPassword: string, pins?: PinStore): Promise<void> {
  const { status, body } = await sealedPost(server, '/api/change-password', { old_password: oldPassword, new_password: newPassword }, { token, pins });
  if (status !== 204 && status !== 200) throwStatus(status, body);
}

export async function logout(server: string, token: string, pins?: PinStore): Promise<void> {
  try {
    const { status } = await sealedPost(server, '/api/logout', {}, { token, pins });
    if (status !== 204 && status !== 200 && status !== 401) {
      // Best-effort; a missing token is already logged out.
    }
  } catch {
    // Ignore network errors on logout.
  }
}
