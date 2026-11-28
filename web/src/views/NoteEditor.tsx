import { useEffect, useMemo, useState } from 'react';
import type { SyncEngine } from '../sync/engine';
import { isCompleted, shortTitle, STICKY_COLORS, stickyColorOf, type Block } from '../protocol/types';
import { renderMarkdown } from '../ui/markdown';
import { Icons } from '../ui/icons';

export function NoteEditor({
  sync,
  block,
  parentId,
  onClose,
}: {
  sync: SyncEngine;
  block: Block | null;
  parentId?: string | null;
  onClose: () => void;
}) {
  const current = block ? sync.byId(block.id) ?? block : null;
  const [title, setTitle] = useState(current?.title ?? '');
  const [md, setMd] = useState(String(current?.payload.markdown ?? ''));
  const [split, setSplit] = useState(window.innerWidth >= 860);
  const [tick, setTick] = useState(0);

  useEffect(() => {
    const id = current?.id;
    if (!id) return;
    return sync.subscribe(() => {
      const b = sync.byId(id);
      if (!b) return;
      // Don't yank the caret if we just wrote the same text.
      setTick((n) => n + 1);
    });
  }, [sync, current?.id]);

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if ((e.metaKey || e.ctrlKey) && e.key === 's') {
        e.preventDefault();
        save();
      }
      if ((e.metaKey || e.ctrlKey) && e.key === 'b') {
        e.preventDefault();
        wrap('**');
      }
      if ((e.metaKey || e.ctrlKey) && e.key === 'i') {
        e.preventDefault();
        wrap('_');
      }
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [title, md, current]);

  function wrap(mark: string) {
    setMd((v) => v + mark + mark);
  }

  function save(nextTitle = title, nextMd = md) {
    const t = nextTitle.trim() || shortTitle(nextMd) || '未命名笔记';
    if (current) {
      sync.update(current.id, { title: t, payload: { ...current.payload, markdown: nextMd } });
    }
  }

  function ensure(): Block {
    if (current) return current;
    const t = title.trim() || shortTitle(md) || '未命名笔记';
    const b = sync.create({ kind: 'note', title: t, payload: { markdown: md }, parentId });
    return b;
  }

  useEffect(() => {
    if (!current && (title || md)) {
      // create on first content
    }
  }, [current, title, md]);

  const color = current ? stickyColorOf(current) : STICKY_COLORS[STICKY_COLORS.length - 1]!;
  const done = current ? isCompleted(current) : false;
  const html = useMemo(() => renderMarkdown(md), [md, tick]);

  return (
    <section className="page glass">
      <header className="page-head">
        <button className="icon-btn" onClick={() => { save(); onClose(); }} aria-label="返回"><Icons.back /></button>
        <input className="field" style={{ border: 0, background: 'transparent', height: 36, flex: 1 }} value={title} placeholder="标题" onChange={(e) => { setTitle(e.target.value); }} onBlur={() => save()} />
        <button className="icon-btn" title="预览分栏" onClick={() => setSplit((v) => !v)}>{split ? '预览' : '编辑'}</button>
        {current && (
          <>
            <button className="icon-btn" title="优先级" onClick={() => cycleColor(sync, current)} style={{ color: color.color ?? undefined }}>●</button>
            <button className="icon-btn" title={done ? '取消完成' : '标为已完成'} onClick={() => toggleComplete(sync, current)}>
              {done ? <Icons.checkCircle /> : <Icons.circle />}
            </button>
          </>
        )}
      </header>
      <div className="format-bar" style={{ padding: '0 16px' }}>
        <button className="pill" type="button" onClick={() => prefix('# ')}>H1</button>
        <button className="pill" type="button" onClick={() => prefix('## ')}>H2</button>
        <button className="pill" type="button" onClick={() => setMd((v) => v + '**粗体**')}>B</button>
        <button className="pill" type="button" onClick={() => setMd((v) => v + '_斜体_')}>I</button>
        <button className="pill" type="button" onClick={() => prefix('- ')}>列表</button>
        <button className="pill" type="button" onClick={() => prefix('- [ ] ')}>待办</button>
        <button className="pill" type="button" onClick={() => setMd((v) => v + '\n```\n\n```\n')}>代码</button>
      </div>
      <div className="page-body" style={{ display: 'flex', flexDirection: 'column', minHeight: 0 }}>
        <div className={split ? 'editor-split' : 'note-single'} style={{ flex: 1, minHeight: 0 }}>
          <textarea
            value={md}
            placeholder="开始写 Markdown…"
            onChange={(e) => {
              const v = e.target.value;
              setMd(v);
              const b = current ?? ensure();
              const t = title.trim() || shortTitle(v) || '未命名笔记';
              if (!title.trim() && shortTitle(v)) setTitle(shortTitle(v));
              sync.update(b.id, { title: t, payload: { ...b.payload, markdown: v } });
            }}
          />
          {split && <div className="md-preview" dangerouslySetInnerHTML={{ __html: html }} />}
        </div>
      </div>
    </section>
  );

  function prefix(p: string) {
    setMd((v) => (v ? `${v}\n${p}` : p));
  }
}

export function cycleColor(sync: SyncEngine, b: Block) {
  const cur = stickyColorOf(b).key;
  const i = STICKY_COLORS.findIndex((c) => c.key === cur);
  const next = STICKY_COLORS[(i + 1) % STICKY_COLORS.length]!;
  const payload = { ...b.payload };
  if (next.key === 'default') delete payload.sticky_color;
  else payload.sticky_color = next.key;
  sync.update(b.id, { payload });
}

export function toggleComplete(sync: SyncEngine, b: Block) {
  const payload = { ...b.payload };
  if (isCompleted(b)) {
    delete payload.completed;
    delete payload.completed_at;
  } else {
    payload.completed = true;
    payload.completed_at = Date.now();
  }
  sync.update(b.id, { payload });
}
