import { describe, expect, it } from 'vitest';
import { endpoint, normalizeServer, wsUrl } from '../src/protocol/url';

describe('normalizeServer', () => {
  it('adds https for domain names and http for IPs / localhost', () => {
    expect(normalizeServer('notes.example.com')).toBe('https://notes.example.com');
    expect(normalizeServer('192.168.1.10:7700')).toBe('http://192.168.1.10:7700');
    expect(normalizeServer('localhost:7700')).toBe('http://localhost:7700');
    expect(normalizeServer('syncnotes.local:7700')).toBe('http://syncnotes.local:7700');
  });

  it('keeps an explicit scheme and strips a trailing /ws', () => {
    expect(normalizeServer('http://notes.example.com/ws')).toBe('http://notes.example.com');
    expect(normalizeServer('wss://notes.example.com/ws/')).toBe('https://notes.example.com');
  });

  it('builds health, seal and websocket endpoints', () => {
    expect(endpoint('http://127.0.0.1:7700', '/health')).toBe('http://127.0.0.1:7700/health');
    expect(endpoint('https://notes.example.com/app', '/api/seal')).toBe('https://notes.example.com/app/api/seal');
    expect(wsUrl('https://notes.example.com')).toBe('wss://notes.example.com/ws');
    expect(wsUrl('192.168.0.5:7700')).toBe('ws://192.168.0.5:7700/ws');
  });
});
