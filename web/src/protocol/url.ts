/** Normalize a user-entered server address the same way the native client does. */
export function normalizeServer(raw: string): string {
  let s = raw.trim();
  if (!s) return s;
  s = s.replace(/\/+$/, '');
  if (/^wss?:\/\//i.test(s)) s = s.replace(/^ws/i, 'http');
  if (!/^[a-z][a-z0-9+.-]*:\/\//i.test(s)) {
    const host = s.split('/')[0] ?? s;
    const name = host.split(':')[0] ?? host;
    const useHttp =
      name === 'localhost' ||
      name === '127.0.0.1' ||
      name === '[::1]' ||
      name.endsWith('.local') ||
      /^\d{1,3}(?:\.\d{1,3}){3}$/.test(name);
    s = `${useHttp ? 'http' : 'https'}://${s}`;
  }
  const u = new URL(s);
  let path = u.pathname.endsWith('/') && u.pathname.length > 1 ? u.pathname.slice(0, -1) : u.pathname;
  if (path.endsWith('/ws')) path = path.slice(0, -3) || '/';
  u.pathname = path || '/';
  u.hash = '';
  // Keep an empty path as origin without a trailing slash except the root.
  let out = u.toString();
  if (u.pathname === '/' && out.endsWith('/')) out = out.slice(0, -1);
  return out;
}

export function httpBase(server: string): URL {
  const s = normalizeServer(server).replace(/^ws/i, 'http');
  return new URL(s);
}

export function endpoint(server: string, path: string, query?: Record<string, string>): string {
  const base = httpBase(server);
  const p = path.startsWith('/') ? path : `/${path}`;
  const joined = `${base.pathname.replace(/\/$/, '')}${p}` || p;
  const u = new URL(joined, `${base.origin}/`);
  if (query) for (const [k, v] of Object.entries(query)) u.searchParams.set(k, v);
  return u.toString();
}

export function wsUrl(server: string): string {
  const u = new URL(endpoint(server, '/ws'));
  u.protocol = u.protocol === 'https:' ? 'wss:' : 'ws:';
  return u.toString();
}
