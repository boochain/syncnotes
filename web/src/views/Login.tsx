import { useEffect, useState } from 'react';
import { changePassword, fetchHealth, login, recover, register } from '../api/http';
import { SealPinMismatch, shortFp } from '../crypto/seal';
import { ApiError } from '../api/http';
import type { AuthResponse } from '../protocol/types';
import { normalizeServer } from '../protocol/url';
import { deviceName, type Session } from '../store/session';
import { Icons } from '../ui/icons';

type Mode = 'login' | 'register' | 'recover';

export function LoginView({
  initialServer,
  pins,
  deviceId,
  onDone,
  onClearPin,
}: {
  initialServer: string;
  pins: { get(s: string): string | undefined; set(s: string, h: string): void; clear(s: string): void };
  deviceId: string;
  onDone: (s: Session, recovery?: string) => void;
  onClearPin: (server: string) => void;
}) {
  const [mode, setMode] = useState<Mode>('login');
  const [server, setServer] = useState(initialServer);
  const [user, setUser] = useState('');
  const [password, setPassword] = useState('');
  const [password2, setPassword2] = useState('');
  const [code, setCode] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const [health, setHealth] = useState('');
  const [mismatch, setMismatch] = useState<SealPinMismatch | null>(null);
  const [forceChange, setForceChange] = useState<Session | null>(null);
  const [newPw, setNewPw] = useState('');

  useEffect(() => {
    setServer(initialServer);
  }, [initialServer]);

  async function probe() {
    const s = normalizeServer(server);
    if (!s) return;
    try {
      const h = await fetchHealth(s);
      setHealth(`已连接 ${h.version} · 协议 ${h.protocol ?? '?'}`);
      setError('');
    } catch (e) {
      setHealth('');
      setError(e instanceof Error ? e.message : '无法连接');
    }
  }

  async function submit(ev?: { preventDefault(): void }) {
    ev?.preventDefault();
    setError('');
    setMismatch(null);
    const s = normalizeServer(server);
    if (!s) return setError('请填写服务器地址');
    if (user.trim().length < 2) return setError('用户名长度需在 2-32 之间');
    setBusy(true);
    try {
      let r: AuthResponse;
      if (mode === 'register') {
        if (password !== password2) throw new ApiError('两次输入的密码不一致');
        r = await register(s, user.trim(), password, pins);
      } else if (mode === 'recover') {
        if (password !== password2) throw new ApiError('两次输入的密码不一致');
        r = await recover(s, user.trim(), code, password, deviceId, deviceName(), pins);
      } else {
        r = await login(s, user.trim(), password, deviceId, deviceName(), pins);
      }
      const sess: Session = {
        server: s,
        token: r.token,
        userId: r.user_id,
        username: r.username,
        mustChangePassword: !!r.must_change_password,
        hasRecoveryCode: !!r.has_recovery_code,
      };
      if (sess.mustChangePassword && mode === 'login') setForceChange(sess);
      else onDone(sess, r.recovery_code ?? undefined);
    } catch (e) {
      if (e instanceof SealPinMismatch) setMismatch(e);
      else setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  }

  async function doChange() {
    if (!forceChange) return;
    setBusy(true);
    setError('');
    try {
      await changePassword(forceChange.server, forceChange.token, password, newPw, pins);
      onDone({ ...forceChange, mustChangePassword: false });
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  }

  if (forceChange) {
    return (
      <div className="login">
        <form className="login-card glass" onSubmit={(e) => { e.preventDefault(); void doChange(); }}>
          <h1>设置新密码</h1>
          <p className="lead">管理员重置了临时密码，登录前需要改成你自己的密码。笔记数据没有改动。</p>
          <div className="stack">
            <input className="field" type="password" placeholder="新密码（至少 4 位）" value={newPw} onChange={(e) => setNewPw(e.target.value)} autoFocus />
            {error && <div className="error">{error}</div>}
            <button className="primary" disabled={busy || newPw.length < 4} type="submit">{busy ? '提交中…' : '保存并进入'}</button>
          </div>
        </form>
      </div>
    );
  }

  // 与 App 登录页同一结构：应用图标 + 标题 + 分组表单（每行 44 高、左侧图标、细分隔线）+ 主按钮 + 文字链接
  const submitLabel = busy ? '请稍候…' : mode === 'login' ? '登录' : mode === 'register' ? '注册并登录' : '重置密码并登录';
  return (
    <div className="login">
      <form className="login-col" onSubmit={submit}>
        <div className="app-mark" aria-hidden><Icons.sync size={28} strokeWidth={2.2} /></div>
        <h1>SyncNotes</h1>
        <p className="lead">{mode === 'recover' ? '用恢复码设置新密码，笔记不会丢失' : '多设备实时同步的笔记与消息'}</p>
        <div className="form-group glass">
          <label className="form-row">
            <Icons.globe size={17} />
            <input aria-label="服务器地址" placeholder="服务器地址，例如 192.168.1.8:7700" value={server} onChange={(e) => setServer(e.target.value)} onBlur={() => void probe()} autoCapitalize="off" autoCorrect="off" />
          </label>
          <label className="form-row">
            <Icons.person size={17} />
            <input aria-label="用户名" placeholder="用户名" value={user} onChange={(e) => setUser(e.target.value)} autoComplete="username" />
          </label>
          {mode === 'recover' && (
            <label className="form-row">
              <Icons.key size={17} />
              <input aria-label="恢复码" placeholder="恢复码（形如 AAAAA-AAAAA-AAAAA-AAAAA）" value={code} onChange={(e) => setCode(e.target.value)} autoCapitalize="characters" />
            </label>
          )}
          <label className="form-row">
            <Icons.lock size={17} />
            <input aria-label={mode === 'recover' ? '新密码' : '密码'} type="password" placeholder={mode === 'recover' ? '新密码' : '密码'} value={password} onChange={(e) => setPassword(e.target.value)} autoComplete={mode === 'login' ? 'current-password' : 'new-password'} />
          </label>
          {mode !== 'login' && (
            <label className="form-row">
              <Icons.lock size={17} />
              <input aria-label="再输入一次密码" type="password" placeholder="再输入一次密码" value={password2} onChange={(e) => setPassword2(e.target.value)} autoComplete="new-password" />
            </label>
          )}
        </div>
        {health && <div className="hint center">{health}</div>}
        {error && <div className="error center" role="alert">{error}</div>}
        {mismatch && (
          <div className="stack">
            <div className="error center">{mismatch.message}</div>
            <div className="hint center">上次 {shortFp(mismatch.saved)}，这次 {shortFp(mismatch.current)}</div>
            <button type="button" className="ghost" onClick={() => { onClearPin(normalizeServer(server)); setMismatch(null); void submit(); }}>
              我确认这是同一台服务器，清除旧指纹并重试
            </button>
          </div>
        )}
        <button className="primary block" disabled={busy} type="submit">{submitLabel}</button>
        <div className="links">
          {mode === 'login' ? (
            <>
              <button type="button" className="link" onClick={() => setMode('register')}>没有账号？注册</button>
              <button type="button" className="link" onClick={() => setMode('recover')}>忘记密码？</button>
            </>
          ) : (
            <button type="button" className="link" onClick={() => setMode('login')}>已有账号？去登录</button>
          )}
        </div>
        <div className="hint center fine">传输走 syncnotes-seal-v1 加密；网页版是独立静态站点，不内嵌在服务器进程里。</div>
      </form>
    </div>
  );
}
