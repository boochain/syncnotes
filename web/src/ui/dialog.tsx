import { useEffect, useRef, useState } from 'react';
import { Popup } from './presence';

/** v0.8.2：替代浏览器原生 confirm / prompt，统一为不透明卡片对话框（打开时下层淡出只露背景）。 */
type Req = { kind: 'confirm' | 'prompt'; title: string; danger?: boolean; ok?: string; resolve: (v: string | boolean | null) => void };

let current: Req | null = null;
const subs = new Set<() => void>();
function set(r: Req | null) { current = r; subs.forEach((f) => f()); }

export function askConfirm(title: string, opts: { danger?: boolean; ok?: string } = {}): Promise<boolean> {
  return new Promise((resolve) => set({ kind: 'confirm', title, ...opts, resolve: (v) => resolve(v === true) }));
}
export function askText(title: string, opts: { ok?: string } = {}): Promise<string | null> {
  return new Promise((resolve) => set({ kind: 'prompt', title, ...opts, resolve: (v) => resolve(typeof v === 'string' ? v : null) }));
}

export function DialogHost() {
  const [req, setReq] = useState<Req | null>(current);
  const [text, setText] = useState('');
  const input = useRef<HTMLInputElement>(null);
  useEffect(() => { const f = () => { setReq(current); setText(''); }; subs.add(f); return () => { subs.delete(f); }; }, []);
  useEffect(() => { if (req?.kind === 'prompt') setTimeout(() => input.current?.focus(), 160); }, [req]);
  const done = (v: string | boolean | null) => { const r = req; set(null); r?.resolve(v); };
  const open = req !== null;
  return (
    <Popup open={open} onClose={() => done(null)} label={req?.title}>
      {req && (
        <div className="dialog-wrap">
          <form className="dialog popup-card" role="dialog" aria-modal="true" aria-label={req.title}
            onSubmit={(e) => { e.preventDefault(); done(req.kind === 'prompt' ? (text.trim() || null) : true); }}>
            <h3>{req.title}</h3>
            {req.kind === 'prompt' && <input ref={input} className="field" value={text} onChange={(e) => setText(e.target.value)} />}
            <div className="dialog-actions">
              <button type="button" className="ghost" onClick={() => done(null)}>取消</button>
              <button type="submit" className={req.danger ? 'primary danger-fill' : 'primary'}>{req.ok ?? '确定'}</button>
            </div>
          </form>
        </div>
      )}
    </Popup>
  );
}
