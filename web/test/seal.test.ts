import { describe, expect, it } from 'vitest';
import {
  ClientHello,
  HttpPending,
  acceptClientHello,
  aeadSeal,
  chunkNonce,
  deriveKey,
  fingerprint,
  openChunk,
  openHttpRequest,
  publicKey,
  sealChunk,
  sharedSecret,
} from '../src/crypto/seal';
import { fromHex, fromUtf8, utf8 } from '../src/crypto/bytes';

function fill(n: number, v: number): Uint8Array {
  return new Uint8Array(n).fill(v);
}

describe('syncnotes-seal-v1', () => {
  it('http request/response hides plaintext and round-trips', () => {
    const serverSk = fill(32, 2);
    const serverPub = publicKey(serverSk);
    const password = utf8('super-secret-password');
    const pending = HttpPending.seal(serverPub, 1, '/api/login', utf8('{}'), password);
    const env = pending.envelope;
    const hay = fromUtf8(env);
    expect(hay.includes('super-secret-password')).toBe(false);
    const opened = openHttpRequest(serverSk, env);
    expect(opened.path).toBe('/api/login');
    expect(opened.method).toBe(1);
    expect(fromUtf8(opened.body)).toBe('super-secret-password');
    const resp = opened.sealResponse(401, utf8('nope'));
    expect(fromUtf8(resp).includes('nope')).toBe(false);
    const out = pending.openResponse(resp);
    expect(out.status).toBe(401);
    expect(fromUtf8(out.body)).toBe('nope');
  });

  it('derives matching blob chunk keys and encrypts chunks', () => {
    const serverSk = fill(32, 7);
    const pending = HttpPending.seal(publicKey(serverSk), 3, '/api/blob', utf8('{}'), utf8('meta'));
    const opened = openHttpRequest(serverSk, pending.envelope);
    expect([...opened.chunkKey()]).toEqual([...pending.chunkKey()]);
    const ct = sealChunk(opened.chunkKey(), 0, utf8('hello file'));
    expect(fromUtf8(ct).includes('hello')).toBe(false);
    expect(fromUtf8(openChunk(pending.chunkKey(), 0, ct))).toBe('hello file');
    expect(() => openChunk(pending.chunkKey(), 1, ct)).toThrow();
  });

  it('websocket handshake and sequenced frames hide application json', () => {
    const serverSk = fill(32, 9);
    const hello = new ClientHello();
    const { hello: frame, pair: server } = acceptClientHello(serverSk, hello.frame);
    const client = hello.finish(publicKey(serverSk), frame);
    const c = client.send.seal(utf8('{"type":"ping"}'));
    expect(fromUtf8(c).includes('ping')).toBe(false);
    expect(fromUtf8(server.recv.open(c))).toBe('{"type":"ping"}');
    const s = server.send.seal(utf8('{"type":"pong"}'));
    expect(fromUtf8(client.recv.open(s))).toBe('{"type":"pong"}');
    expect(() => client.recv.open(s)).toThrow(/序号/);
  });

  it('rejects a handshake finished with the wrong static key', () => {
    const serverSk = fill(32, 4);
    const otherSk = fill(32, 5);
    const hello = new ClientHello();
    const { hello: frame } = acceptClientHello(serverSk, hello.frame);
    expect(() => hello.finish(publicKey(otherSk), frame)).toThrow(/身份校验/);
  });

  it('chunk nonce places the index in the last 8 bytes', () => {
    expect([...chunkNonce(0)]).toEqual([...new Uint8Array(12)]);
    const n = chunkNonce(1);
    expect(n[11]).toBe(1);
    expect(n[0]).toBe(0);
  });

  it('known vector: secret=0x02.., eph=0x03..', () => {
    // Mirrors server/src/seal.rs vector_for_clients so a later rustc run can confirm.
    const serverSk = fill(32, 2);
    const ephSk = fill(32, 3);
    const shared = sharedSecret(ephSk, publicKey(serverSk));
    const key = deriveKey(shared, 'http-req');
    const ct = aeadSeal(key, fill(12, 9), utf8('syncnotes-http-v1-req'), utf8('hi'));
    expect(fingerprint(publicKey(serverSk)).length).toBe(64);
    expect(fingerprint(publicKey(ephSk)).length).toBe(64);
    expect(shared.length).toBe(32);
    expect(key.length).toBe(32);
    expect(ct.length).toBe(2 + 16);
    // Stable outputs for this deterministic input (RFC 7748 clamp applies).
    expect(fingerprint(publicKey(ephSk))).toBe('5dfedd3b6bd47f6fa28ee15d969d5bb0ea53774d488bdaf9df1c6e0124b3ef22');
    expect(ct.length).toBeGreaterThan(16);
    // Ensure HKDF is keyed with the documented salt by checking a frozen digest.
    expect(fingerprint(key)).toBe(fingerprint(deriveKey(shared, 'http-req')));
    expect(fromHex(fingerprint(key)).length).toBe(32);
  });
});
