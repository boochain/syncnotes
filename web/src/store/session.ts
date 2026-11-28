import type { PinStore } from '../api/http';

const DEVICE = 'syncnotes-web-device-id';
const SESSION = 'syncnotes-web-session';
const PINS = 'syncnotes-web-pins';
const SETTINGS = 'syncnotes-web-settings';

export interface Session {
  server: string;
  token: string;
  userId: string;
  username: string;
  mustChangePassword: boolean;
  hasRecoveryCode: boolean;
}

export type ThemeMode = 'system' | 'light' | 'dark';
export type GlassQuality = 'high' | 'medium' | 'low' | 'off';
export type InboxView = 'canvas' | 'list';
export type FilterKind = 'all' | 'message' | 'note' | 'file' | 'folder' | 'page';

export interface UiSettings {
  theme: ThemeMode;
  fluid: boolean;
  glassOpacity: number; // 0.2–0.9
  refraction: number; // 0–1
  quality: GlassQuality;
  inboxView: InboxView;
  defaultViewedMode: 'per_device' | 'global';
}

export const defaultSettings: UiSettings = {
  theme: 'system',
  fluid: true,
  glassOpacity: 0.52,
  refraction: 0.65,
  quality: 'high',
  inboxView: 'canvas',
  defaultViewedMode: 'per_device',
};

export function getDeviceId(): string {
  let id = localStorage.getItem(DEVICE);
  if (!id) {
    id = crypto.randomUUID();
    localStorage.setItem(DEVICE, id);
  }
  return id;
}

export function loadSession(): Session | null {
  try {
    const raw = localStorage.getItem(SESSION);
    if (!raw) return null;
    const j = JSON.parse(raw) as Session;
    if (!j.server || !j.token || !j.username) return null;
    return j;
  } catch {
    return null;
  }
}

export function saveSession(s: Session | null): void {
  if (!s) localStorage.removeItem(SESSION);
  else localStorage.setItem(SESSION, JSON.stringify(s));
}

export function loadSettings(): UiSettings {
  try {
    const raw = localStorage.getItem(SETTINGS);
    if (!raw) return { ...defaultSettings };
    return { ...defaultSettings, ...(JSON.parse(raw) as Partial<UiSettings>) };
  } catch {
    return { ...defaultSettings };
  }
}

export function saveSettings(s: UiSettings): void {
  localStorage.setItem(SETTINGS, JSON.stringify(s));
}

export function pinStore(): PinStore {
  const read = (): Record<string, string> => {
    try {
      return JSON.parse(localStorage.getItem(PINS) ?? '{}') as Record<string, string>;
    } catch {
      return {};
    }
  };
  return {
    get: (server) => read()[server],
    set: (server, hex) => {
      const all = read();
      all[server] = hex;
      localStorage.setItem(PINS, JSON.stringify(all));
    },
    clear: (server) => {
      const all = read();
      delete all[server];
      localStorage.setItem(PINS, JSON.stringify(all));
    },
  };
}

export async function loadRuntimeConfig(): Promise<{ defaultServer: string }> {
  try {
    const res = await fetch('./config.json', { cache: 'no-store' });
    if (!res.ok) return { defaultServer: '' };
    const j = (await res.json()) as { defaultServer?: string };
    return { defaultServer: (j.defaultServer ?? '').trim() };
  } catch {
    return { defaultServer: '' };
  }
}

export function deviceName(): string {
  const ua = navigator.userAgent;
  let os = '浏览器';
  if (/Windows/i.test(ua)) os = 'Windows';
  else if (/Mac OS X/i.test(ua)) os = 'macOS';
  else if (/Android/i.test(ua)) os = 'Android';
  else if (/iPhone|iPad/i.test(ua)) os = 'iOS';
  else if (/Linux/i.test(ua)) os = 'Linux';
  return `网页版 · ${os}`;
}
