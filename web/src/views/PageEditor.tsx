import { useMemo, useRef, useState } from 'react';
import type { SyncEngine } from '../sync/engine';
import { DOC_TYPES, docText, docTypeOf, orderOf, type Block, type DocType } from '../protocol/types';
import { Icons } from '../ui/icons';

const LABELS: Record<DocType, string> = {
  paragraph: '正文',
  heading1: '标题 1',
  heading2: '标题 2',
  heading3: '标题 3',
  bullet: '项目列表',
  numbered: '编号列表',
  todo: '待办',
  toggle: '折叠块',
  quote: '引用',
  code: '代码',
  divider: '分隔线',
};

export function PageEditor({ sync, page, onClose, onOpenPage }: { sync: SyncEngine; page: Block; onClose: () => void; onOpenPage: (id: string) => void }) {
  const live = sync.byId(page.id) ?? page;
  const [title, setTitle] = useState(live.title);
  const [slash, setSlash] = useState<{ id: string; x: number; y: number; q: string } | null>(null);
  const ref = useRef<HTMLDivElement>(null);

  const children = useMemo(() => {
    return sync
      .all()
      .filter((b) => b.parent_id === live.id && b.kind === 'text' && !b.deleted && !b.deleted_at)
      .sort((a, b) => orderOf(a) - orderOf(b));
  }, [sync, live.id, live.updated_at, sync.pendingCount, sync.latestSeq]);

  function ensureBlock(): Block {
    if (children.length) return children[0]!;
    return sync.create({
      kind: 'text',
      title: '',
      parentId: live.id,
      payload: { type: 'paragraph', text: '', order: Date.now() },
    });
  }

  function setText(b: Block, text: string, ev?: React.ChangeEvent<HTMLTextAreaElement>) {
    if (text.startsWith('/') && !docText(b)) {
      const r = ev?.target.getBoundingClientRect();
      setSlash({ id: b.id, x: r?.left ?? 80, y: (r?.bottom ?? 80) + 4, q: text.slice(1) });
    } else if (slash?.id === b.id) {
      if (text.startsWith('/')) setSlash({ ...slash, q: text.slice(1) });
      else setSlash(null);
    }
    sync.update(b.id, { payload: { ...b.payload, text } });
    const el = ev?.target;
    if (el) {
      el.style.height = 'auto';
      el.style.height = `${el.scrollHeight}px`;
    }
  }

  function applyType(b: Block, type: DocType) {
    const extra: Record<string, unknown> = { type, text: '' };
    if (type === 'todo') extra.checked = false;
    sync.update(b.id, { payload: { ...b.payload, ...extra } });
    setSlash(null);
  }

  function onKey(b: Block, i: number, e: React.KeyboardEvent<HTMLTextAreaElement>) {
    if (e.key === 'Enter' && !e.shiftKey) {
      e.preventDefault();
      const after = orderOf(b) + 1;
      const nb = sync.create({
        kind: 'text',
        title: '',
        parentId: live.id,
        payload: { type: docTypeOf(b) === 'todo' ? 'todo' : 'paragraph', text: '', order: after, ...(docTypeOf(b) === 'todo' ? { checked: false } : {}) },
      });
      queueMicrotask(() => document.getElementById(`doc-${nb.id}`)?.focus());
    }
    if (e.key === 'Backspace' && !docText(b) && children.length > 1) {
      e.preventDefault();
      sync.purge([b.id]);
      const prev = children[i - 1] ?? children[i + 1];
      if (prev) queueMicrotask(() => document.getElementById(`doc-${prev.id}`)?.focus());
    }
  }

  const filtered = slash
    ? DOC_TYPES.filter((t) => LABELS[t].includes(slash.q) || t.includes(slash.q.toLowerCase()))
    : [];

  return (
    <section className="page glass" ref={ref}>
      <header className="page-head">
        <button className="icon-btn" onClick={onClose} aria-label="返回"><Icons.back /></button>
        <input
          className="field"
          style={{ border: 0, background: 'transparent', height: 36, flex: 1, fontSize: 18, fontWeight: 650 }}
          value={title}
          placeholder="无标题页面"
          onChange={(e) => {
            setTitle(e.target.value);
            sync.update(live.id, { title: e.target.value || '无标题页面' });
          }}
        />
        <button className="pill" onClick={() => { ensureBlock(); }}>添加块</button>
      </header>
      <div className="page-body">
        {children.length === 0 && (
          <p className="hint" style={{ cursor: 'text' }} onClick={() => ensureBlock()}>
            输入文字，或按 / 打开块菜单
          </p>
        )}
        {children.map((b, i) => {
          const t = docTypeOf(b);
          if (t === 'divider') {
            return <hr key={b.id} style={{ border: 0, borderTop: '1px solid var(--line)', margin: '16px 0' }} />;
          }
          return (
            <div key={b.id} className={`doc-block doc-${t === 'heading1' ? 'h1' : t === 'heading2' ? 'h2' : t === 'heading3' ? 'h3' : t}`}>
              {t === 'todo' && (
                <input
                  type="checkbox"
                  checked={b.payload.checked === true}
                  onChange={(e) => sync.update(b.id, { payload: { ...b.payload, checked: e.target.checked } })}
                  style={{ marginTop: 8 }}
                />
              )}
              {(t === 'bullet' || t === 'numbered') && <span style={{ marginTop: 6, color: 'var(--text2)' }}>{t === 'bullet' ? '•' : `${i + 1}.`}</span>}
              <textarea
                id={`doc-${b.id}`}
                defaultValue={docText(b)}
                key={b.id}
                placeholder={t === 'paragraph' ? '输入 / 选择块类型' : LABELS[t]}
                rows={1}
                onChange={(e) => setText(b, e.target.value, e)}
                onKeyDown={(e) => onKey(b, i, e)}
              />
            </div>
          );
        })}
        {sync
          .childrenOf(live.id)
          .filter((b) => b.kind === 'page')
          .map((p) => (
            <button key={p.id} className="side-item" onClick={() => onOpenPage(p.id)}>
              <Icons.page /> {p.title || '子页面'}
            </button>
          ))}
      </div>
      {slash && (
        <div className="slash glass" style={{ left: slash.x, top: slash.y, position: 'fixed' }}>
          {filtered.map((t) => (
            <button key={t} className="side-item" onClick={() => {
              const b = sync.byId(slash.id);
              if (b) applyType(b, t);
            }}>
              {LABELS[t]}
            </button>
          ))}
          {filtered.length === 0 && <div className="hint" style={{ padding: 8 }}>没有匹配的块类型</div>}
        </div>
      )}
    </section>
  );
}
