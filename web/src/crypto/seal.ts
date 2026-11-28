import { chacha20poly1305 } from '@noble/ciphers/chacha.js';
import { x25519 } from '@noble/curves/ed25519.js';
import { hkdf } from '@noble/hashes/hkdf.js';
import { sha256 } from '@noble/hashes/sha2.js';
import { concat, equal, fromB64, hex, randomBytes, readU16be, readU64be, u16be, u64be, utf8 } from './bytes';

export const HTTP_MAGIC = utf8('SNC1');
export const WS_MAGIC = utf8('SNW1');
export const WS_DATA = utf8('SND1');
export const CHUNK_SIZE = 256 * 1024;
export const MAX_CHUNK = 1024 * 1024;
export const SALT = utf8('syncnotes-seal-v1');

export class SealError extends Error {
  fatal: boolean;
  constructor(message: string, fatal = false) {
    super(message);
    this.name = 'SealError';
    this.fatal = fatal;
  }
}

export class SealPinMismatch extends SealError {
  saved: string;
  current: string;
  constructor(saved: string, current: string) {
    super(
      `服务器指纹和上次不一致（${shortFp(saved)} → ${shortFp(current)}）。指纹是这台服务器的长期公钥，用来确认还是同一台。它变了通常是重装、换了数据目录，或地址被指到别处。不确定原因不要继续。`,
      true,
    );
    this.name = 'SealPinMismatch';
    this.saved = saved;
    this.current = current;
  }
}

export function shortFp(h: string): string {
  return h.length <= 16 ? h : `${h.slice(0, 8)}…${h.slice(-4)}`;
}

export function deriveKey(ikm: Uint8Array, info: string): Uint8Array {
  return hkdf(sha256, ikm, SALT, utf8(info), 32);
}

export function sharedSecret(secret: Uint8Array, remotePub: Uint8Array): Uint8Array {
  return x25519.getSharedSecret(secret, remotePub);
}

export function publicKey(secret: Uint8Array): Uint8Array {
  return x25519.getPublicKey(secret);
}

export function newSecret(): Uint8Array {
  return x25519.keygen().secretKey;
}

function aead(key: Uint8Array, nonce: Uint8Array, aad: Uint8Array) {
  return chacha20poly1305(key, nonce, aad);
}

export function aeadSeal(key: Uint8Array, nonce: Uint8Array, aad: Uint8Array, plain: Uint8Array): Uint8Array {
  return aead(key, nonce, aad).encrypt(plain);
}

export function aeadOpen(key: Uint8Array, nonce: Uint8Array, aad: Uint8Array, ct: Uint8Array): Uint8Array {
  try {
    return aead(key, nonce, aad).decrypt(ct);
  } catch {
    throw new SealError('无法解密');
  }
}

export function parsePubB64(s: string): Uint8Array {
  const v = fromB64(s);
  if (v.length !== 32) throw new SealError('服务器公钥无效', true);
  return v;
}

export function parsePubHex(s: string): Uint8Array {
  const clean = s.trim().toLowerCase();
  if (!/^[0-9a-f]{64}$/.test(clean)) throw new SealError('服务器公钥无效', true);
  const out = new Uint8Array(32);
  for (let i = 0; i < 32; i++) out[i] = parseInt(clean.slice(i * 2, i * 2 + 2), 16);
  return out;
}

export function fingerprint(pub: Uint8Array): string {
  return hex(pub);
}

/** method: 1 POST, 2 GET, 3 PUT */
export class HttpPending {
  readonly envelope: Uint8Array;
  private readonly ephSecret: Uint8Array;
  private readonly serverPub: Uint8Array;
  private _shared?: Uint8Array;

  private constructor(ephSecret: Uint8Array, serverPub: Uint8Array, envelope: Uint8Array) {
    this.ephSecret = ephSecret;
    this.serverPub = serverPub;
    this.envelope = envelope;
  }

  static seal(
    serverPub: Uint8Array,
    method: number,
    path: string,
    headersJson: Uint8Array,
    body: Uint8Array,
  ): HttpPending {
    const ephSecret = newSecret();
    const ephPub = publicKey(ephSecret);
    const shared = sharedSecret(ephSecret, serverPub);
    const key = deriveKey(shared, 'http-req');
    const pb = utf8(path);
    const plain = concat(new Uint8Array([method & 0xff]), u16be(pb.length), pb, u16be(headersJson.length), headersJson, body);
    const nonce = randomBytes(12);
    const ct = aeadSeal(key, nonce, utf8('syncnotes-http-v1-req'), plain);
    const envelope = concat(HTTP_MAGIC, ephPub, nonce, ct);
    const p = new HttpPending(ephSecret, serverPub, envelope);
    p._shared = shared;
    return p;
  }

  shared(): Uint8Array {
    return (this._shared ??= sharedSecret(this.ephSecret, this.serverPub));
  }

  openResponse(envelope: Uint8Array): { status: number; body: Uint8Array } {
    const plain = openEnvelope(envelope, this.shared(), 'http-res', 'syncnotes-http-v1-res');
    if (plain.length < 2) throw new SealError('响应损坏');
    const status = readU16be(plain, 0);
    return { status, body: plain.slice(2) };
  }

  chunkKey(): Uint8Array {
    return deriveKey(this.shared(), 'blob');
  }
}

function openEnvelope(envelope: Uint8Array, shared: Uint8Array, info: string, aad: string): Uint8Array {
  if (envelope.length < 48 + 16 || !equal(envelope.subarray(0, 4), HTTP_MAGIC)) {
    throw new SealError('加密通道无效');
  }
  const nonce = envelope.subarray(36, 48);
  const key = deriveKey(shared, info);
  return aeadOpen(key, nonce, utf8(aad), envelope.subarray(48));
}

export function chunkNonce(idx: number): Uint8Array {
  const n = new Uint8Array(12);
  n.set(u64be(idx), 4);
  return n;
}

export function sealChunk(key: Uint8Array, idx: number, plain: Uint8Array): Uint8Array {
  return aeadSeal(key, chunkNonce(idx), utf8('syncnotes-blob-v1'), plain);
}

export function openChunk(key: Uint8Array, idx: number, ct: Uint8Array): Uint8Array {
  return aeadOpen(key, chunkNonce(idx), utf8('syncnotes-blob-v1'), ct);
}

function dirNonce(dir: number, seq: number): Uint8Array {
  const n = new Uint8Array(12);
  n[0] = dir;
  n.set(u64be(seq), 1);
  return n;
}

export class WsDir {
  private seq = 0;
  constructor(
    private readonly key: Uint8Array,
    private readonly dir: number,
  ) {}

  seal(plain: Uint8Array): Uint8Array {
    this.seq += 1;
    const nonce = dirNonce(this.dir, this.seq);
    const aad = concat(utf8('syncnotes-ws-v1'), new Uint8Array([this.dir]));
    const ct = aeadSeal(this.key, nonce, aad, plain);
    return concat(WS_DATA, u64be(this.seq), ct);
  }

  open(frame: Uint8Array): Uint8Array {
    if (frame.length < 4 + 8 + 16 || !equal(frame.subarray(0, 4), WS_DATA)) {
      throw new SealError('无法解密');
    }
    const seq = readU64be(frame, 4);
    if (seq !== this.seq + 1) throw new SealError('帧序号错误');
    this.seq = seq;
    const nonce = dirNonce(this.dir, seq);
    const aad = concat(utf8('syncnotes-ws-v1'), new Uint8Array([this.dir]));
    return aeadOpen(this.key, nonce, aad, frame.subarray(12));
  }
}

export class WsPair {
  constructor(
    readonly send: WsDir,
    readonly recv: WsDir,
  ) {}
}

export class ClientHello {
  readonly frame: Uint8Array;
  private readonly ephSecret: Uint8Array;

  constructor(secret?: Uint8Array) {
    this.ephSecret = secret ?? newSecret();
    this.frame = concat(WS_MAGIC, publicKey(this.ephSecret));
  }

  finish(serverPub: Uint8Array, serverFrame: Uint8Array): WsPair {
    if (serverFrame.length !== 4 + 32 + 16 || !equal(serverFrame.subarray(0, 4), WS_MAGIC)) {
      throw new SealError('加密握手失败', true);
    }
    const serverEph = serverFrame.subarray(4, 36);
    const tag = serverFrame.subarray(36);
    const ssE = sharedSecret(this.ephSecret, serverEph);
    const ssS = sharedSecret(this.ephSecret, serverPub);
    const key = deriveKey(concat(ssE, ssS), 'ws');
    const clientEph = publicKey(this.ephSecret);
    const aad = concat(clientEph, serverEph);
    const expect = aeadSeal(key, new Uint8Array(12), aad, new Uint8Array());
    if (!equal(expect, tag)) throw new SealError('服务器身份校验失败', true);
    return new WsPair(new WsDir(key, 1), new WsDir(key, 2));
  }
}

/** Server-side helpers used only in tests to prove interop with the official framing. */
export function acceptClientHello(staticSecret: Uint8Array, frame: Uint8Array): { hello: Uint8Array; pair: WsPair } {
  if (frame.length !== 36 || !equal(frame.subarray(0, 4), WS_MAGIC)) {
    throw new SealError('加密握手失败', true);
  }
  const clientEph = frame.subarray(4, 36);
  const eph = newSecret();
  const serverEph = publicKey(eph);
  const ssE = sharedSecret(eph, clientEph);
  const ssS = sharedSecret(staticSecret, clientEph);
  const key = deriveKey(concat(ssE, ssS), 'ws');
  const aad = concat(clientEph, serverEph);
  const tag = aeadSeal(key, new Uint8Array(12), aad, new Uint8Array());
  const hello = concat(WS_MAGIC, serverEph, tag);
  return { hello, pair: new WsPair(new WsDir(key, 2), new WsDir(key, 1)) };
}

export function openHttpRequest(staticSecret: Uint8Array, envelope: Uint8Array): {
  method: number;
  path: string;
  headersJson: Uint8Array;
  body: Uint8Array;
  shared: Uint8Array;
  sealResponse: (status: number, body: Uint8Array) => Uint8Array;
  chunkKey: () => Uint8Array;
} {
  if (envelope.length < 48 + 16 || !equal(envelope.subarray(0, 4), HTTP_MAGIC)) {
    throw new SealError('加密通道无效');
  }
  const ephPub = envelope.subarray(4, 36);
  const nonce = envelope.subarray(36, 48);
  const shared = sharedSecret(staticSecret, ephPub);
  const key = deriveKey(shared, 'http-req');
  const plain = aeadOpen(key, nonce, utf8('syncnotes-http-v1-req'), envelope.subarray(48));
  if (plain.length < 5) throw new SealError('请求损坏');
  const method = plain[0]!;
  const pathLen = readU16be(plain, 1);
  if (plain.length < 3 + pathLen + 2) throw new SealError('请求损坏');
  const path = new TextDecoder().decode(plain.subarray(3, 3 + pathLen));
  const h0 = 3 + pathLen;
  const hdrLen = readU16be(plain, h0);
  if (plain.length < h0 + 2 + hdrLen) throw new SealError('请求损坏');
  const headersJson = plain.subarray(h0 + 2, h0 + 2 + hdrLen);
  const body = plain.subarray(h0 + 2 + hdrLen);
  return {
    method,
    path,
    headersJson,
    body,
    shared,
    sealResponse(status, respBody) {
      const p = concat(u16be(status), respBody);
      const n = randomBytes(12);
      const k = deriveKey(shared, 'http-res');
      const ct = aeadSeal(k, n, utf8('syncnotes-http-v1-res'), p);
      return concat(HTTP_MAGIC, new Uint8Array(32), n, ct);
    },
    chunkKey: () => deriveKey(shared, 'blob'),
  };
}
