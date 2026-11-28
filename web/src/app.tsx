import { useCallback, useEffect, useMemo, useRef, useState, type CSSProperties } from 'react';
import { changePassword, forgetServerPub, logout, regenerateRecoveryCode, type PinStore } from './api/http';
import { FluidBackdrop, applyChrome } from './ui/glass';
import { CardLayer, Popup } from './ui/presence';
import { DialogHost, askConfirm, askText } from './ui/dialog';
import { Icons, KindIcon } from './ui/icons';
import { LoginView } from './views/Login';
import { NoteEditor, cycleColor, toggleComplete } from './views/NoteEditor';
import { PageEditor } from './views/PageEditor';
import { renderMarkdown, plainPreview } from './ui/markdown';
import { SyncEngine, type SyncPersist } from './sync/engine';
import {
  deviceName,
  getDeviceId,
  loadRuntimeConfig,
  loadSession,
  loadSettings,
  pinStore,
  saveSession,
  saveSettings,
  type FilterKind,
  type InboxView,
  type Session,
  type UiSettings,
} from './store/session';
import { TransferQueue, formatSize, formatSpeed } from './store/transfers';
import {
  blockPriority,
  isCompleted,
  isViewed,
  shortTitle,
  stickyColorOf,
  type Block,
} from './protocol/types';
import { fetchHealth } from './api/http';
import { hex } from './crypto/bytes';
import { sha256 } from '@noble/hashes/sha2.js';
import { isTaskBlock, taskProgress, toggledTaskPayload } from './features/tasks';
import { TasksPage } from './views/TasksPage';
import { CalendarPage } from './views/CalendarPage';

type Route =
  | { name: 'inbox' }
  | { name: 'note'; id?: string; parentId?: string | null }
  | { name: 'page'; id: string }
  | { name: 'folder'; id: string }
  | { name: 'trash' }
  | { name: 'transfers' }
  | { name: 'settings' }
  | { name: 'tasks'; focus?: string }
  | { name: 'calendar' };

function persist(server: string, userId: string): SyncPersist {
  const key = `syncnotes-web-cache:${server}:${userId}`;
  return {
    load() {
      try {
        const raw = localStorage.getItem(key);
        return raw ? (JSON.parse(raw) as ReturnType<SyncPersist['load']>) : null;
      } catch {
        return null;
      }
    },
    save(data) {
      try {
        localStorage.setItem(key, JSON.stringify(data));
      } catch {
        /* quota */
      }
    },
  };
}

function resolveTheme(mode: UiSettings['theme']): 'light' | 'dark' {
  if (mode === 'light' || mode === 'dark') return mode;
  return window.matchMedia?.('(prefers-color-scheme: light)').matches ? 'light' : 'dark';
}

export function App() {
  const deviceId = useMemo(() => getDeviceId(), []);
  const pins = useMemo(() => pinStore(), []);
  const transfers = useMemo(() => new TransferQueue(), []);
  const [session, setSession] = useState<Session | null>(() => loadSession());
  const [settings, setSettings] = useState<UiSettings>(() => loadSettings());
  const [theme, setTheme] = useState<'light' | 'dark'>(() => resolveTheme(loadSettings().theme));
  const [route, setRoute] = useState<Route>({ name: 'inbox' });
  const [tick, setTick] = useState(0);
  const [query, setQuery] = useState('');
  const [filter, setFilter] = useState<FilterKind>('all');
  const [toast, setToast] = useState('');
  const [compose, setCompose] = useState('');
  const [plusOpen, setPlusOpen] = useState(false);
  const [ctx, setCtx] = useState<{ x: number; y: number; id: string } | null>(null);
  const [recovery, setRecovery] = useState<string | null>(null);
  const [defaultServer, setDefaultServer] = useState('');
  const [parentId, setParentId] = useState<string | null>(null);
  const engine = useRef<SyncEngine | null>(null);
  const [, setXferTick] = useState(0);

  useEffect(() => {
    void (async () => {
      const cfg = await loadRuntimeConfig();
      if (cfg.defaultServer) setDefaultServer(cfg.defaultServer);
      else {
        try {
          const origin = window.location.origin;
          const h = await fetchHealth(origin);
          if (h.seal_pub) setDefaultServer(origin);
        } catch {
          /* not same-origin */
        }
      }
    })();
  }, []);

  useEffect(() => {
    applyChrome(settings);
    const t = resolveTheme(settings.theme);
    setTheme(t);
    document.documentElement.dataset.theme = t;
    const mq = window.matchMedia?.('(prefers-color-scheme: light)');
    const on = () => {
      if (settings.theme === 'system') {
        const n = resolveTheme('system');
        setTheme(n);
        document.documentElement.dataset.theme = n;
      }
    };
    mq?.addEventListener?.('change', on);
    return () => mq?.removeEventListener?.('change', on);
  }, [settings]);

  useEffect(() => {
    return transfers.subscribe(() => setXferTick((n) => n + 1));
  }, [transfers]);

  const bump = useCallback(() => setTick((n) => n + 1), []);

  useEffect(() => {
    if (!session) {
      engine.current?.disconnect();
      engine.current = null;
      return;
    }
    const sync = new SyncEngine(deviceId, persist(session.server, session.userId), pins);
    engine.current = sync;
    const off = sync.subscribe(bump);
    sync.onRemoteNew = (b) => {
      if (b.kind !== 'text') showToast(`新${kindLabel(b.kind)}：${b.title || '未命名'}`);
    };
    sync.connect(session.server, session.token);
    return () => {
      off();
      sync.dispose();
      if (engine.current === sync) engine.current = null;
    };
  }, [session, deviceId, pins, bump]);

  useEffect(() => {
    if (!toast) return;
    const t = setTimeout(() => setToast(''), 2800);
    return () => clearTimeout(t);
  }, [toast]);

  function showToast(s: string) {
    setToast(s);
  }

  function updateSettings(p: Partial<UiSettings>) {
    const next = { ...settings, ...p };
    setSettings(next);
    saveSettings(next);
  }

  function signedIn(s: Session, code?: string) {
    saveSession(s);
    setSession(s);
    if (code) setRecovery(code);
  }

  async function signOut() {
    if (session) await logout(session.server, session.token, pins);
    saveSession(null);
    setSession(null);
    setRoute({ name: 'inbox' });
  }

  const sync = engine.current;
  const dark = theme === 'dark';

  return (
    <div className="app">
      <FluidBackdrop dark={dark} refraction={settings.refraction} quality={settings.quality} enabled={settings.fluid} />
      <div className="layer">
        {!session || !sync ? (
          <LoginView
            initialServer={session?.server || defaultServer}
            pins={pins}
            deviceId={deviceId}
            onDone={signedIn}
            onClearPin={(s) => {
              pins.clear(s);
              forgetServerPub(s);
            }}
          />
        ) : (
          <Shell
            session={session}
            sync={sync}
            settings={settings}
            updateSettings={updateSettings}
            transfers={transfers}
            pins={pins}
            route={route}
            setRoute={(r) => { setRoute(r); if (r.name === 'inbox') setParentId(null); }}
            query={query}
            setQuery={setQuery}
            filter={filter}
            setFilter={setFilter}
            compose={compose}
            setCompose={setCompose}
            plusOpen={plusOpen}
            setPlusOpen={setPlusOpen}
            ctx={ctx}
            setCtx={setCtx}
            parentId={parentId}
            setParentId={setParentId}
            onToast={showToast}
            onSignOut={() => void signOut()}
            tick={tick}
            deviceId={deviceId}
          />
        )}
      </div>
      {toast && <div className="toast glass">{toast}</div>}
      <DialogHost />
      {/* 恢复码只显示这一次：点空白不关闭，必须点「我已保存」，避免误触丢失（与 App 一致）。
          v0.8.2：对话框是不透明卡片，打开时下层界面整体淡出，只露流动背景。 */}
      <Popup open={!!recovery} label="请保存恢复码">
        <div className="login" role="dialog" aria-modal="true" aria-label="请保存恢复码" style={{ position: 'fixed', inset: 0, zIndex: 41, pointerEvents: 'none' }}>
          <div className="login-card popup-card" style={{ pointerEvents: 'auto' }}>
            <h1>请保存恢复码</h1>
            <p className="lead">这是唯一一次完整显示。以后忘记密码时用它重置，笔记数据不会丢失。</p>
            <div className="recovery">{recovery}</div>
            <div className="stack" style={{ marginTop: 16 }}>
              <button className="primary" onClick={() => { if (recovery) void navigator.clipboard.writeText(recovery); showToast('已复制恢复码'); }}>复制</button>
              <button className="ghost" onClick={() => setRecovery(null)}>我已保存</button>
            </div>
          </div>
        </div>
      </Popup>
      {/* tick is read so the tree refreshes with the engine */}
      <span hidden>{tick}</span>
    </div>
  );
}

function Shell(props: {
  session: Session;
  sync: SyncEngine;
  settings: UiSettings;
  updateSettings: (p: Partial<UiSettings>) => void;
  transfers: TransferQueue;
  pins: PinStore;
  route: Route;
  setRoute: (r: Route) => void;
  query: string;
  setQuery: (s: string) => void;
  filter: FilterKind;
  setFilter: (f: FilterKind) => void;
  compose: string;
  setCompose: (s: string) => void;
  plusOpen: boolean;
  setPlusOpen: (v: boolean) => void;
  ctx: { x: number; y: number; id: string } | null;
  setCtx: (v: { x: number; y: number; id: string } | null) => void;
  parentId: string | null;
  setParentId: (id: string | null) => void;
  onToast: (s: string) => void;
  onSignOut: () => void;
  tick: number;
  deviceId: string;
}) {
  const { sync, session, settings, route, setRoute, parentId, setParentId } = props;
  const folder = parentId ? sync.byId(parentId) : null;
  const items = (parentId ? sync.childrenOf(parentId) : sync.childrenOf(null))
    .filter((b) => (props.filter === 'all' ? true : b.kind === props.filter))
    .filter((b) => matchQuery(b, props.query));

  const open = items.filter((b) => !isCompleted(b)).sort(compareInbox);
  const done = items.filter((b) => isCompleted(b)).sort(compareInbox);
  const wide = useWide();

  function goInbox() {
    setParentId(null);
    setRoute({ name: 'inbox' });
  }

  function openBlock(b: Block) {
    if (b.kind === 'folder') {
      setParentId(b.id);
      setRoute({ name: 'folder', id: b.id });
      sync.setViewed(b.id, true);
      return;
    }
    if (b.kind === 'note') {
      sync.setViewed(b.id, true);
      setRoute({ name: 'note', id: b.id });
      return;
    }
    if (b.kind === 'page') {
      sync.setViewed(b.id, true);
      setRoute({ name: 'page', id: b.id });
      return;
    }
    if (b.kind === 'file') {
      void downloadBlock(b);
      sync.setViewed(b.id, true);
      return;
    }
    if (isTaskBlock(b)) {
      sync.setViewed(b.id, true);
      setRoute({ name: 'tasks', focus: b.id });
      return;
    }
    if (b.kind === 'calendar') {
      setRoute({ name: 'calendar' });
      return;
    }
    if (b.kind === 'message') {
      void navigator.clipboard.writeText(String(b.payload.text ?? ''));
      sync.setViewed(b.id, true);
      props.onToast('已复制消息');
    }
  }

  async function downloadBlock(b: Block) {
    const fileId = String(b.payload.file_id ?? '');
    if (!fileId) return props.onToast('文件尚未上传');
    const name = String(b.payload.name ?? b.title ?? 'file');
    props.onToast('开始下载…');
    try {
      const data = await props.transfers.download(session.server, session.token, name, fileId, Number(b.payload.size ?? 0), props.pins);
      const sha = String(b.payload.sha256 ?? '');
      if (sha && hex(sha256(data)) !== sha) throw new Error('文件校验失败');
      const url = URL.createObjectURL(new Blob([data as unknown as BlobPart]));
      const a = document.createElement('a');
      a.href = url;
      a.download = name;
      a.click();
      URL.revokeObjectURL(url);
      props.onToast('下载完成');
    } catch (e) {
      props.onToast(e instanceof Error ? e.message : '下载失败');
    }
  }

  async function uploadFiles(files: FileList | File[]) {
    for (const file of [...files]) {
      const buf = new Uint8Array(await file.arrayBuffer());
      props.transfers
        .upload(session.server, session.token, file.name, buf, props.pins)
        .then((r) => {
          sync.create({
            kind: 'file',
            title: file.name,
            payload: { name: file.name, size: r.size, file_id: r.file_id, sha256: r.sha256 },
            parentId,
            viewedMode: settings.defaultViewedMode,
          });
          props.onToast(`已上传 ${file.name}`);
        })
        .catch((e) => props.onToast(e instanceof Error ? e.message : '上传失败'));
    }
  }

  function sendMessage() {
    const text = props.compose.trim();
    if (!text) return;
    sync.create({
      kind: 'message',
      title: shortTitle(text),
      payload: { text },
      parentId,
      viewedMode: settings.defaultViewedMode,
    });
    props.setCompose('');
  }

  const noteBlock = route.name === 'note' && route.id ? sync.byId(route.id) ?? null : null;
  const pageBlock = route.name === 'page' ? sync.byId(route.id) : undefined;
  const fabRef = useRef<HTMLButtonElement>(null);
  // 新建菜单挂在 body 上，按「+」按钮的位置定位在它上方
  const plusMenuPos = (): CSSProperties => {
    const r = fabRef.current?.getBoundingClientRect();
    if (!r) return { position: 'fixed', right: 16, bottom: 80 };
    return { position: 'fixed', right: Math.max(8, window.innerWidth - r.right), bottom: window.innerHeight - r.top + 10, top: 'auto', left: 'auto' };
  };
  const [covered, setCoveredState] = useState(false);
  const setCovered = useCallback((c: boolean) => setCoveredState(c), []);
  const overlay = route.name === 'note' || route.name === 'page' || route.name === 'trash' || route.name === 'transfers' || route.name === 'settings' || route.name === 'tasks' || route.name === 'calendar';

  return (
    <div
      className={`shell ${wide ? '' : 'no-side'} ${covered ? 'covered' : ''}`}
      onDragOver={(e) => { e.preventDefault(); }}
      onDrop={(e) => { e.preventDefault(); if (e.dataTransfer.files.length) void uploadFiles(e.dataTransfer.files); }}
      onClick={() => { props.setPlusOpen(false); props.setCtx(null); }}
    >
      {wide && (
        <aside className="sidebar glass">
          <div style={{ padding: '16px 16px 8px', display: 'flex', alignItems: 'center', gap: 10 }}>
            <span className="avatar">{session.username.slice(0, 1).toUpperCase()}</span>
            <div>
              <div style={{ fontWeight: 650 }}>{session.username}</div>
              <ConnStatus sync={sync} />
            </div>
          </div>
          <nav className="side-nav">
            <button className={`side-item ${route.name === 'inbox' && !parentId ? 'active' : ''}`} onClick={goInbox}>收件箱</button>
            <button className={`side-item ${route.name === 'tasks' ? 'active' : ''}`} onClick={() => setRoute({ name: 'tasks' })}>
              <Icons.task size={16} /> 任务
            </button>
            <button className={`side-item ${route.name === 'calendar' ? 'active' : ''}`} onClick={() => setRoute({ name: 'calendar' })}>
              <Icons.calendar size={16} /> 日历
            </button>
            <button className={`side-item ${route.name === 'trash' ? 'active' : ''}`} onClick={() => setRoute({ name: 'trash' })}>
              <Icons.trash size={16} /> 回收站{sync.trash.length ? ` · ${sync.trash.length}` : ''}
            </button>
            <button className={`side-item ${route.name === 'transfers' ? 'active' : ''}`} onClick={() => setRoute({ name: 'transfers' })}>
              <Icons.transfer size={16} /> 传输{props.transfers.active.length ? ` · ${props.transfers.active.length}` : ''}
            </button>
            <button className={`side-item ${route.name === 'settings' ? 'active' : ''}`} onClick={() => setRoute({ name: 'settings' })}>
              <Icons.settings size={16} /> 设置
            </button>
          </nav>
          <div className="page-tree">
            <div className="section-h">页面</div>
            {sync.visible().filter((b) => b.kind === 'page' && !b.parent_id).map((p) => (
              <button key={p.id} className={`page-item ${route.name === 'page' && route.id === p.id ? 'active' : ''}`} onClick={() => setRoute({ name: 'page', id: p.id })}>
                <Icons.page size={15} /> {p.title || '无标题页面'}
              </button>
            ))}
            <div className="section-h">文件夹</div>
            {sync.visible().filter((b) => b.kind === 'folder' && !b.parent_id).map((f) => (
              <button key={f.id} className={`page-item ${parentId === f.id ? 'active' : ''}`} onClick={() => { setParentId(f.id); setRoute({ name: 'folder', id: f.id }); }}>
                <Icons.folder size={15} /> {f.title || '文件夹'}
              </button>
            ))}
          </div>
        </aside>
      )}
      <main className="main" style={{ position: 'relative' }}>
        <header className="topbar">
          <div className="left">
            <button className="avatar" title={session.username} onClick={() => setRoute({ name: 'settings' })}>{session.username.slice(0, 1).toUpperCase()}</button>
            {parentId && (
              <button className="icon-btn" onClick={() => { const p = sync.byId(parentId)?.parent_id ?? null; setParentId(p); setRoute(p ? { name: 'folder', id: p } : { name: 'inbox' }); }} aria-label="返回"><Icons.back /></button>
            )}
          </div>
          <div className="brand">
            <h1>{folder ? folder.title : 'SyncNotes'}</h1>
            <ConnStatus sync={sync} />
          </div>
          <div className="right">
            {!wide && (
              <>
                <button className="icon-btn" onClick={() => setRoute({ name: 'tasks' })} aria-label="任务"><Icons.task /></button>
                <button className="icon-btn" onClick={() => setRoute({ name: 'calendar' })} aria-label="日历"><Icons.calendar /></button>
                <button className="icon-btn" onClick={() => setRoute({ name: 'trash' })} aria-label="回收站"><Icons.trash /></button>
                <button className="icon-btn" onClick={() => setRoute({ name: 'transfers' })} aria-label="传输"><Icons.transfer /></button>
              </>
            )}
            <button className="icon-btn" onClick={() => setRoute({ name: 'settings' })} aria-label="设置"><Icons.settings /></button>
          </div>
        </header>
        <div className="toolbar">
          {(['all', 'message', 'note', 'page', 'file', 'folder'] as FilterKind[]).map((f) => (
            <button key={f} className={`pill ${props.filter === f ? 'active' : ''}`} onClick={() => props.setFilter(f)}>
              {f === 'all' ? '全部' : kindLabel(f)}
            </button>
          ))}
          <div className="search-wrap">
            <Icons.search size={16} />
            <input className="search" placeholder="搜索" value={props.query} onChange={(e) => props.setQuery(e.target.value)} onClick={(e) => e.stopPropagation()} />
          </div>
          <button
            className="icon-btn"
            title={settings.inboxView === 'canvas' ? '切换到列表' : '切换到画布'}
            onClick={() => props.updateSettings({ inboxView: settings.inboxView === 'canvas' ? 'list' : 'canvas' })}
          >
            {settings.inboxView === 'canvas' ? <Icons.list /> : <Icons.canvas />}
          </button>
          {settings.inboxView === 'canvas' && (
            <button className="icon-btn" title="整理排列" onClick={() => arrange(sync, open)}><Icons.arrange /></button>
          )}
        </div>
        <div className="inbox">
          {open.length === 0 && done.length === 0 && <div className="empty">还没有内容。在下方发一条消息，或点右下角加号新建。</div>}
          {settings.inboxView === 'list' || !wide ? (
            <div className="grid">
              {open.map((b) => (
                <Card key={b.id} block={b} sync={sync} onOpen={() => openBlock(b)} onCtx={(e) => { e.preventDefault(); e.stopPropagation(); props.setCtx({ x: e.clientX, y: e.clientY, id: b.id }); }} />
              ))}
            </div>
          ) : (
            <Canvas items={open} sync={sync} onOpen={openBlock} onCtx={(e, id) => { e.preventDefault(); e.stopPropagation(); props.setCtx({ x: e.clientX, y: e.clientY, id }); }} />
          )}
          {done.length > 0 && (
            <>
              <div className="section-h">已完成 · {done.length}</div>
              <div className="grid">
                {done.map((b) => (
                  <Card key={b.id} block={b} sync={sync} onOpen={() => openBlock(b)} onCtx={(e) => { e.preventDefault(); e.stopPropagation(); props.setCtx({ x: e.clientX, y: e.clientY, id: b.id }); }} />
                ))}
              </div>
            </>
          )}
        </div>
        <form className="composer glass" onSubmit={(e) => { e.preventDefault(); sendMessage(); }} onClick={(e) => e.stopPropagation()}>
          <input className="field" placeholder="写一条消息，回车发送" value={props.compose} onChange={(e) => props.setCompose(e.target.value)} />
          <button ref={fabRef} className="fab" type="button" onClick={(e) => { e.stopPropagation(); props.setPlusOpen(!props.plusOpen); }} aria-label="新建"><Icons.plus /></button>
        </form>
        <Popup open={props.plusOpen} onClose={() => props.setPlusOpen(false)} label="新建">
          <div className="menu popup-card" style={plusMenuPos()} onClick={(e) => e.stopPropagation()}>
              <button type="button" onClick={() => { props.setPlusOpen(false); setRoute({ name: 'note', parentId }); }}><Icons.note size={16} /> Markdown 笔记</button>
              <button type="button" onClick={() => { props.setPlusOpen(false); const p = sync.create({ kind: 'page', title: '无标题页面', parentId, viewedMode: settings.defaultViewedMode }); setRoute({ name: 'page', id: p.id }); }}><Icons.page size={16} /> 页面</button>
              <button type="button" onClick={() => { props.setPlusOpen(false); void askText('文件夹名称', { ok: '创建' }).then((name) => { if (name) sync.create({ kind: 'folder', title: name.trim(), parentId, viewedMode: settings.defaultViewedMode, payload: { icon: 'folder' } }); }); }}><Icons.folder size={16} /> 文件夹</button>
              <button type="button" onClick={() => {
                props.setPlusOpen(false);
                const input = document.createElement('input');
                input.type = 'file';
                input.multiple = true;
                input.onchange = () => { if (input.files) void uploadFiles(input.files); };
                input.click();
              }}><Icons.file size={16} /> 文件</button>
            </div>
        </Popup>
        <CardLayer open={overlay} onCover={setCovered}>
            {route.name === 'note' && (
              <NoteEditor sync={sync} block={noteBlock} parentId={route.parentId ?? parentId} onClose={goBack} />
            )}
            {route.name === 'page' && pageBlock && (
              <PageEditor sync={sync} page={pageBlock} onClose={goBack} onOpenPage={(id) => setRoute({ name: 'page', id })} />
            )}
            {route.name === 'tasks' && (
              <TasksPage sync={sync} tick={props.tick} focus={route.focus} onClose={goBack} />
            )}
            {route.name === 'calendar' && <CalendarPage sync={sync} tick={props.tick} onClose={goBack} />}
            {route.name === 'trash' && <TrashPage sync={sync} onClose={goBack} onToast={props.onToast} />}
            {route.name === 'transfers' && <TransfersPage transfers={props.transfers} onClose={goBack} />}
            {route.name === 'settings' && (
              <SettingsPage
                session={session}
                sync={sync}
                settings={settings}
                updateSettings={props.updateSettings}
                pins={props.pins}
                onClose={goBack}
                onSignOut={props.onSignOut}
                onToast={props.onToast}
                onRecovery={(c) => props.onToast('已生成新恢复码，请立即保存')}
                setRecovery={(c) => {
                  const ev = new CustomEvent('syncnotes-recovery', { detail: c });
                  window.dispatchEvent(ev);
                }}
              />
            )}
        </CardLayer>
      </main>
      <Popup open={!!props.ctx} onClose={() => props.setCtx(null)} label="上下文菜单">
      {props.ctx && (
        <ContextMenu
          x={props.ctx.x}
          y={props.ctx.y}
          block={sync.byId(props.ctx.id)}
          sync={sync}
          onClose={() => props.setCtx(null)}
          onOpen={() => { const b = sync.byId(props.ctx!.id); if (b) openBlock(b); }}
          onDownload={(b) => void downloadBlock(b)}
        />
      )}
      </Popup>
    </div>
  );

  function goBack() {
    if (parentId) setRoute({ name: 'folder', id: parentId });
    else setRoute({ name: 'inbox' });
  }
}

function ConnStatus({ sync }: { sync: SyncEngine }) {
  const s = sync.connState;
  const label = s === 'online' ? '已连接' : s === 'connecting' ? '连接中' : s === 'authError' ? '需要重新登录' : '离线';
  const cls = s === 'online' ? 'on' : s === 'connecting' ? 'warn' : 'off';
  return (
    <div className="status"><span className={`dot ${cls}`} />{label}{sync.pendingCount ? ` · ${sync.pendingCount} 待同步` : ''}{sync.lastError && s !== 'online' ? ` · ${sync.lastError}` : ''}</div>
  );
}

function compareInbox(a: Block, b: Block) {
  const dp = (isCompleted(a) ? 1 : 0) - (isCompleted(b) ? 1 : 0);
  if (dp) return dp;
  const pr = blockPriority(b) - blockPriority(a);
  if (pr) return pr;
  return a.created_at - b.created_at;
}

function matchQuery(b: Block, q: string) {
  if (!q.trim()) return true;
  const s = q.trim().toLowerCase();
  const body = JSON.stringify(b.payload).toLowerCase();
  return b.title.toLowerCase().includes(s) || body.includes(s);
}

function kindLabel(k: string) {
  return k === 'message' ? '消息' : k === 'note' ? '笔记' : k === 'file' ? '文件' : k === 'folder' ? '文件夹' : k === 'page' ? '页面' : k === 'task' ? '任务' : k === 'calendar' ? '日历' : k;
}

function Card({ block, sync, onOpen, onCtx }: { block: Block; sync: SyncEngine; onOpen: () => void; onCtx: (e: React.MouseEvent) => void }) {
  const color = stickyColorOf(block);
  const done = isCompleted(block);
  const unread = !isViewed(block) && !done;
  const preview = previewOf(block, sync);
  return (
    <article className="card glass-lite" onClick={onOpen} onContextMenu={onCtx} style={{ borderColor: color.color ? `${color.color}66` : undefined }}>
      <div className="card-head">
        <span className="kind-dot" style={{ background: (color.color ?? 'var(--fill2)'), color: color.color ? '#111' : 'var(--text2)' }}><KindIcon kind={block.kind} /></span>
        <div className={`title ${done ? 'done' : ''}`}>{block.title || kindLabel(block.kind)}</div>
        {unread && <span className="unread" />}
      </div>
      <div className="preview">{preview}</div>
      <div className="meta">
        {color.tag && !done && <span className="tag" style={{ color: color.color ?? undefined, background: `${color.color}22` }}>{color.tag}</span>}
        {done && <span className="tag" style={{ color: 'var(--success)', background: 'color-mix(in srgb, var(--success) 18%, transparent)' }}>已完成</span>}
        {isTaskBlock(block) && <span>{Math.round(taskProgress(block, sync.blockMap()) * 100)}%</span>}
        <span>{timeAgo(block.updated_at)}</span>
      </div>
    </article>
  );
}

function Canvas({ items, sync, onOpen, onCtx }: { items: Block[]; sync: SyncEngine; onOpen: (b: Block) => void; onCtx: (e: React.MouseEvent, id: string) => void }) {
  const [drag, setDrag] = useState<{ id: string; dx: number; dy: number; x: number; y: number; z: number } | null>(null);
  const maxZ = items.reduce((m, b) => Math.max(m, Number(b.payload.sticky_z ?? 0)), 0);

  return (
    <div className="canvas" style={{ height: Math.max(640, ...items.map((b, i) => posOf(b, i).y + 200)) }}>
      {items.map((b, i) => {
        const p = drag?.id === b.id ? { x: drag.x, y: drag.y } : posOf(b, i);
        const z = drag?.id === b.id ? drag.z : Number(b.payload.sticky_z ?? i);
        return (
          <article
            key={b.id}
            className={`sticky glass ${drag?.id === b.id ? 'dragging' : ''}`}
            style={{ left: p.x, top: p.y, zIndex: z, borderColor: stickyColorOf(b).color ? `${stickyColorOf(b).color}66` : undefined }}
            onClick={() => onOpen(b)}
            onContextMenu={(e) => onCtx(e, b.id)}
            onPointerDown={(e) => {
              if (e.button !== 0) return;
              const start = { x: e.clientX, y: e.clientY };
              let moved = false;
              const origin = posOf(b, i);
              const onMove = (ev: PointerEvent) => {
                const x = Math.max(0, origin.x + ev.clientX - start.x);
                const y = Math.max(0, origin.y + ev.clientY - start.y);
                if (Math.hypot(ev.clientX - start.x, ev.clientY - start.y) > 4) moved = true;
                setDrag({ id: b.id, dx: 0, dy: 0, x, y, z: maxZ + 1 });
              };
              const onUp = (ev: PointerEvent) => {
                window.removeEventListener('pointermove', onMove);
                window.removeEventListener('pointerup', onUp);
                if (moved) {
                  ev.preventDefault();
                  const x = Math.max(0, origin.x + ev.clientX - start.x);
                  const y = Math.max(0, origin.y + ev.clientY - start.y);
                  sync.update(b.id, { payload: { ...b.payload, sticky_x: Math.round(x), sticky_y: Math.round(y), sticky_z: maxZ + 1 } });
                }
                setDrag(null);
              };
              window.addEventListener('pointermove', onMove);
              window.addEventListener('pointerup', onUp);
            }}
          >
            <div className="sticky-head">
              <span className="kind-dot" style={{ background: stickyColorOf(b).color ?? 'var(--fill2)' }}><KindIcon kind={b.kind} /></span>
              <div className={`title ${isCompleted(b) ? 'done' : ''}`}>{b.title || kindLabel(b.kind)}</div>
            </div>
            <div className="preview">{previewOf(b, sync)}</div>
            <div className="meta"><span>{timeAgo(b.updated_at)}</span></div>
          </article>
        );
      })}
    </div>
  );
}

function posOf(b: Block, i: number) {
  const x = Number(b.payload.sticky_x);
  const y = Number(b.payload.sticky_y);
  if (Number.isFinite(x) && Number.isFinite(y)) return { x, y };
  const col = i % 3;
  const row = Math.floor(i / 3);
  return { x: 16 + col * 250, y: 8 + row * 180 };
}

function arrange(sync: SyncEngine, items: Block[]) {
  items.forEach((b, i) => {
    const p = { x: 16 + (i % 3) * 250, y: 8 + Math.floor(i / 3) * 180 };
    sync.update(b.id, { payload: { ...b.payload, sticky_x: p.x, sticky_y: p.y, sticky_z: i + 1 } });
  });
}

function previewOf(b: Block, sync: SyncEngine): string {
  if (b.kind === 'message') return String(b.payload.text ?? '');
  if (b.kind === 'note') return plainPreview(String(b.payload.markdown ?? ''), b.title);
  if (b.kind === 'file') return `${b.payload.name ?? b.title} · ${formatSize(Number(b.payload.size ?? 0))}`;
  if (b.kind === 'folder') {
    const n = sync.childrenOf(b.id).length;
    return `${n} 项`;
  }
  if (b.kind === 'page') return '页面';
  if (isTaskBlock(b)) return `任务 · 进度 ${Math.round(taskProgress(b, sync.blockMap()) * 100)}%`;
  if (b.kind === 'calendar') return '日历条目';
  return '';
}

function timeAgo(ms: number) {
  const d = Date.now() - ms;
  if (d < 60_000) return '刚刚';
  if (d < 3_600_000) return `${Math.floor(d / 60_000)} 分钟前`;
  if (d < 86_400_000) return `${Math.floor(d / 3_600_000)} 小时前`;
  const dt = new Date(ms);
  return `${dt.getMonth() + 1}/${dt.getDate()}`;
}

function useWide() {
  const [w, setW] = useState(() => window.innerWidth >= 860);
  useEffect(() => {
    const on = () => setW(window.innerWidth >= 860);
    window.addEventListener('resize', on);
    return () => window.removeEventListener('resize', on);
  }, []);
  return w;
}

function ContextMenu({ x, y, block, sync, onClose, onOpen, onDownload }: { x: number; y: number; block?: Block; sync: SyncEngine; onClose: () => void; onOpen: () => void; onDownload: (b: Block) => void }) {
  if (!block) return null;
  return (
    <div className="ctx popup-card" style={{ left: Math.min(x, window.innerWidth - 220), top: Math.min(y, window.innerHeight - 240) }} onClick={(e) => e.stopPropagation()}>
      <button className="side-item" onClick={() => { onOpen(); onClose(); }}>打开</button>
      <button className="side-item" onClick={() => { cycleColor(sync, block); onClose(); }}>切换优先级</button>
      <button className="side-item" onClick={() => { if (isTaskBlock(block)) sync.update(block.id, { payload: toggledTaskPayload(block) }); else toggleComplete(sync, block); onClose(); }}>{isCompleted(block) ? '取消完成' : '标为已完成'}</button>
      {block.kind === 'file' && <button className="side-item" onClick={() => { onDownload(block); onClose(); }}>下载</button>}
      {block.kind === 'message' && <button className="side-item" onClick={() => { void navigator.clipboard.writeText(String(block.payload.text ?? '')); onClose(); }}>复制</button>}
      <button className="side-item danger" onClick={() => { sync.delete(block.id); onClose(); }}>移到回收站</button>
    </div>
  );
}

function TrashPage({ sync, onClose, onToast }: { sync: SyncEngine; onClose: () => void; onToast: (s: string) => void }) {
  const [q, setQ] = useState('');
  const items = sync.trash.filter((b) => matchQuery(b, q));
  return (
    <section className="page glass">
      <header className="page-head">
        <button className="icon-btn" onClick={onClose} aria-label="返回"><Icons.back /></button>
        <h2>回收站</h2>
        <button className="ghost" onClick={() => { void askConfirm('清空回收站？此操作不可恢复。', { danger: true, ok: '清空' }).then((ok) => { if (ok) { sync.emptyTrash(); onToast('已清空'); } }); }}>清空</button>
      </header>
      <div className="page-body">
        <p className="hint">默认保留 {sync.trashRetentionDays || '永久'}{sync.trashRetentionDays ? ' 天' : ''}。恢复后旧数据仍在。</p>
        <input className="field" placeholder="搜索回收站" value={q} onChange={(e) => setQ(e.target.value)} style={{ margin: '8px 0 16px' }} />
        {items.length === 0 && <div className="empty">回收站是空的</div>}
        {items.map((b) => (
          <div key={b.id} className="list-row">
            <KindIcon kind={b.kind} />
            <div style={{ flex: 1, minWidth: 0 }}>
              <div className="title">{b.title || kindLabel(b.kind)}</div>
              <div className="hint">{kindLabel(b.kind)}{sync.trashChildCount(b.id) ? ` · ${sync.trashChildCount(b.id)} 个子项` : ''}</div>
            </div>
            <button className="pill" onClick={() => sync.restoreAll([b.id])}>恢复</button>
            <button className="pill danger" onClick={() => { void askConfirm('彻底删除？不可恢复。', { danger: true, ok: '删除' }).then((ok) => { if (ok) sync.purge([b.id]); }); }}>删除</button>
          </div>
        ))}
      </div>
    </section>
  );
}

function TransfersPage({ transfers, onClose }: { transfers: TransferQueue; onClose: () => void }) {
  const [, setT] = useState(0);
  useEffect(() => transfers.subscribe(() => setT((n) => n + 1)), [transfers]);
  return (
    <section className="page glass">
      <header className="page-head">
        <button className="icon-btn" onClick={onClose} aria-label="返回"><Icons.back /></button>
        <h2>传输</h2>
        <button className="ghost" onClick={() => transfers.clearFinished()}>清除已完成</button>
      </header>
      <div className="page-body">
        {transfers.items.length === 0 && <div className="empty">没有传输任务</div>}
        {transfers.items.map((t) => (
          <div key={t.id} className="list-row" style={{ flexWrap: 'wrap' }}>
            <div style={{ width: '100%', display: 'flex', gap: 10, alignItems: 'center' }}>
              {t.kind === 'upload' ? '↑' : '↓'}
              <div style={{ flex: 1, minWidth: 0 }}>
                <div className="title">{t.name}</div>
                <div className="hint">{t.status === 'running' ? formatSpeed(t.speed) : t.status === 'error' ? t.error : t.status === 'done' ? '完成' : t.status === 'canceled' ? '已取消' : '排队'}</div>
              </div>
              <span className="hint">{formatSize(t.done)}{t.total ? ` / ${formatSize(t.total)}` : ''}</span>
              {(t.status === 'running' || t.status === 'queued') && <button className="pill" onClick={() => transfers.cancel(t.id)}>取消</button>}
            </div>
            <div className="progress" style={{ width: '100%', marginTop: 6 }}><span style={{ width: `${t.total ? Math.min(100, (t.done / t.total) * 100) : 0}%` }} /></div>
          </div>
        ))}
      </div>
    </section>
  );
}

function SettingsPage({
  session,
  sync,
  settings,
  updateSettings,
  pins,
  onClose,
  onSignOut,
  onToast,
  setRecovery,
}: {
  session: Session;
  sync: SyncEngine;
  settings: UiSettings;
  updateSettings: (p: Partial<UiSettings>) => void;
  pins: PinStore;
  onClose: () => void;
  onSignOut: () => void;
  onToast: (s: string) => void;
  onRecovery: (c: string) => void;
  setRecovery: (c: string) => void;
}) {
  const [oldPw, setOldPw] = useState('');
  const [newPw, setNewPw] = useState('');
  const [pwForCode, setPwForCode] = useState('');
  const [code, setCode] = useState<string | null>(null);
  const pin = pins.get(session.server);

  return (
    <section className="page glass">
      <header className="page-head">
        <button className="icon-btn" onClick={onClose} aria-label="返回"><Icons.back /></button>
        <h2>设置</h2>
      </header>
      <div className="page-body">
        <div className="settings-group">
          <h3>外观</h3>
          <div className="row-setting">
            <span>主题</span>
            <div style={{ display: 'flex', gap: 6 }}>
              {(['system', 'light', 'dark'] as const).map((m) => (
                <button key={m} className={`pill ${settings.theme === m ? 'active' : ''}`} onClick={() => updateSettings({ theme: m })}>{m === 'system' ? '跟随系统' : m === 'light' ? '浅色' : '深色'}</button>
              ))}
            </div>
          </div>
          <div className="row-setting">
            <span>流体背景</span>
            <button className={`pill ${settings.fluid ? 'active' : ''}`} onClick={() => updateSettings({ fluid: !settings.fluid })}>{settings.fluid ? '开' : '关'}</button>
          </div>
          <div className="row-setting">
            <span>画质</span>
            <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
              {(['high', 'medium', 'low', 'off'] as const).map((q) => (
                <button key={q} className={`pill ${settings.quality === q ? 'active' : ''}`} onClick={() => updateSettings({ quality: q })}>{q === 'high' ? '高' : q === 'medium' ? '中' : q === 'low' ? '低' : '关闭着色器'}</button>
              ))}
            </div>
          </div>
          <div className="row-setting">
            <span>玻璃透明度 {Math.round(settings.glassOpacity * 100)}%</span>
            <input type="range" min={0.2} max={0.9} step={0.01} value={settings.glassOpacity} onChange={(e) => updateSettings({ glassOpacity: Number(e.target.value) })} />
          </div>
          <div className="row-setting">
            <span>折射率 {settings.refraction.toFixed(2)}</span>
            <input type="range" min={0} max={1} step={0.01} value={settings.refraction} onChange={(e) => updateSettings({ refraction: Number(e.target.value) })} />
          </div>
          <p className="hint">折射率会改变流体扭曲、玻璃描边色散和饱和度。低性能设备可改用中/低画质或关闭着色器，界面仍会保留半透明玻璃。</p>
        </div>
        <div className="settings-group">
          <h3>账号</h3>
          <p className="hint">{session.username} · {session.server}</p>
          {pin && <p className="hint">服务器指纹 {pin.slice(0, 8)}…{pin.slice(-4)}</p>}
          <div className="stack">
            <input className="field" type="password" placeholder="当前密码" value={oldPw} onChange={(e) => setOldPw(e.target.value)} />
            <input className="field" type="password" placeholder="新密码" value={newPw} onChange={(e) => setNewPw(e.target.value)} />
            <button className="primary" onClick={async () => {
              try {
                await changePassword(session.server, session.token, oldPw, newPw, pins);
                onToast('密码已修改');
                setOldPw('');
                setNewPw('');
              } catch (e) {
                onToast(e instanceof Error ? e.message : '修改失败');
              }
            }}>修改密码</button>
            <input className="field" type="password" placeholder="当前密码（用于生成恢复码）" value={pwForCode} onChange={(e) => setPwForCode(e.target.value)} />
            <button className="ghost" onClick={async () => {
              try {
                const c = await regenerateRecoveryCode(session.server, session.token, pwForCode, pins);
                setCode(c);
                setRecovery(c);
              } catch (e) {
                onToast(e instanceof Error ? e.message : '生成失败');
              }
            }}>重新生成恢复码</button>
            {code && <div className="recovery">{code}</div>}
          </div>
        </div>
        <div className="settings-group">
          <h3>默认识别状态</h3>
          <div className="row-setting">
            <span>新内容的已读同步</span>
            <button className="pill" onClick={() => updateSettings({ defaultViewedMode: settings.defaultViewedMode === 'global' ? 'per_device' : 'global' })}>
              {settings.defaultViewedMode === 'global' ? '全局已读' : '按设备已读'}
            </button>
          </div>
        </div>
        <button className="ghost danger" onClick={onSignOut}><Icons.logout size={16} /> 退出登录</button>
      </div>
    </section>
  );
}

// keep deviceName referenced for tree-shaking of unused imports in this module
void deviceName;
void renderMarkdown;
