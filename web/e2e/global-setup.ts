import { spawn } from 'node:child_process';
import { mkdtempSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));

/** 启动一个真实的 syncnotes-server（临时目录、随机端口），地址写进 E2E_SERVER。 */
export default async function globalSetup(): Promise<() => Promise<void>> {
  const bin =
    process.env.SYNCNOTES_SERVER_BIN ??
    [resolve(here, '../../server/target/release/syncnotes-server'), resolve(here, '../../server/target/debug/syncnotes-server')].find((p) => existsSync(p));
  if (!bin) throw new Error('找不到 syncnotes-server，请先在 server/ 下 cargo build --release，或设置 SYNCNOTES_SERVER_BIN');
  const dir = mkdtempSync(join(tmpdir(), 'syncnotes-e2e-'));
  const port = 17700 + Math.floor(Math.random() * 2000);
  const proc = spawn(bin, ['--bind', `127.0.0.1:${port}`, '--db', join(dir, 'db.sqlite'), '--files-dir', join(dir, 'files'), '--mdns', 'false'], {
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  let log = '';
  proc.stdout.on('data', (d) => (log += d));
  proc.stderr.on('data', (d) => (log += d));
  const url = `127.0.0.1:${port}`;
  for (let i = 0; i < 100; i++) {
    try {
      const r = await fetch(`http://${url}/health`);
      if (r.ok) break;
    } catch {
      /* not up yet */
    }
    await new Promise((r) => setTimeout(r, 100));
  }
  process.env.E2E_SERVER = url;
  return async () => {
    proc.kill();
    if (/ERROR|panicked/.test(log)) console.error('服务端日志有错误：\n' + log);
  };
}
