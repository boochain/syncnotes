/** Small, dependency-free Markdown renderer. Output is escaped except for the tags we emit. */

export function escapeHtml(s: string): string {
  return s
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

function inline(s: string): string {
  let t = escapeHtml(s);
  t = t.replace(/`([^`]+)`/g, '<code>$1</code>');
  t = t.replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>');
  t = t.replace(/__([^_]+)__/g, '<strong>$1</strong>');
  t = t.replace(/(^|[^*])\*([^*]+)\*/g, '$1<em>$2</em>');
  t = t.replace(/(^|[^_])_([^_]+)_/g, '$1<em>$2</em>');
  t = t.replace(/~~([^~]+)~~/g, '<del>$1</del>');
  t = t.replace(
    /\[([^\]]+)\]\((https?:\/\/[^\s)]+)\)/g,
    '<a href="$2" target="_blank" rel="noopener noreferrer">$1</a>',
  );
  return t;
}

export function renderMarkdown(src: string): string {
  const lines = src.replace(/\r\n/g, '\n').split('\n');
  const out: string[] = [];
  let i = 0;
  let listKind: 'ul' | 'ol' | 'task' | null = null;

  const closeList = () => {
    if (listKind) {
      out.push(listKind === 'ol' ? '</ol>' : '</ul>');
      listKind = null;
    }
  };

  while (i < lines.length) {
    const raw = lines[i] ?? '';
    if (raw.startsWith('```')) {
      closeList();
      const buf: string[] = [];
      i += 1;
      while (i < lines.length && !lines[i]!.startsWith('```')) {
        buf.push(lines[i]!);
        i += 1;
      }
      i += 1;
      out.push(`<pre><code>${escapeHtml(buf.join('\n'))}</code></pre>`);
      continue;
    }
    if (/^\s*---+\s*$/.test(raw)) {
      closeList();
      out.push('<hr/>');
      i += 1;
      continue;
    }
    const h = raw.match(/^(#{1,6})\s+(.*)$/);
    if (h) {
      closeList();
      const n = h[1]!.length;
      out.push(`<h${n}>${inline(h[2]!)}</h${n}>`);
      i += 1;
      continue;
    }
    if (/^>\s?/.test(raw)) {
      closeList();
      const buf: string[] = [];
      while (i < lines.length && /^>\s?/.test(lines[i] ?? '')) {
        buf.push((lines[i] ?? '').replace(/^>\s?/, ''));
        i += 1;
      }
      out.push(`<blockquote>${inline(buf.join('\n'))}</blockquote>`);
      continue;
    }
    const task = raw.match(/^\s*[-*]\s+\[([ xX])\]\s+(.*)$/);
    if (task) {
      if (listKind && listKind !== 'task') closeList();
      if (!listKind) {
        out.push('<ul class="tasks">');
        listKind = 'task';
      }
      const checked = task[1] !== ' ' ? ' checked' : '';
      out.push(`<li><input type="checkbox" disabled${checked}/> ${inline(task[2]!)}</li>`);
      i += 1;
      continue;
    }
    const ul = raw.match(/^\s*[-*+]\s+(.*)$/);
    if (ul) {
      if (listKind && listKind !== 'ul') closeList();
      if (!listKind) {
        out.push('<ul>');
        listKind = 'ul';
      }
      out.push(`<li>${inline(ul[1]!)}</li>`);
      i += 1;
      continue;
    }
    const ol = raw.match(/^\s*\d+\.\s+(.*)$/);
    if (ol) {
      if (listKind && listKind !== 'ol') closeList();
      if (!listKind) {
        out.push('<ol>');
        listKind = 'ol';
      }
      out.push(`<li>${inline(ol[1]!)}</li>`);
      i += 1;
      continue;
    }
    if (!raw.trim()) {
      closeList();
      i += 1;
      continue;
    }
    closeList();
    const buf: string[] = [raw];
    i += 1;
    while (i < lines.length && lines[i]!.trim() && !/^(#|```|>|\s*[-*+] |\s*\d+\. |\s*---+\s*$)/.test(lines[i]!)) {
      buf.push(lines[i]!);
      i += 1;
    }
    out.push(`<p>${inline(buf.join('\n'))}</p>`);
  }
  closeList();
  return out.join('') || '<p></p>';
}

export function plainPreview(md: string, title = ''): string {
  const lines = md
    .split('\n')
    .map((l) => l.replace(/^\s*(?:#{1,6}\s+|[-*+]\s+|\d+\.\s+|>\s*|- \[[ xX]\]\s+)/, ''))
    .map((l) => l.replace(/[`*_~#]/g, ''))
    .map((l) => l.trim())
    .filter((l) => l && l !== title.trim());
  return lines.join(' · ');
}
