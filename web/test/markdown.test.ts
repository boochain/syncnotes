import { describe, expect, it } from 'vitest';
import { escapeHtml, plainPreview, renderMarkdown } from '../src/ui/markdown';

describe('markdown', () => {
  it('escapes HTML before rendering', () => {
    expect(escapeHtml('<script>alert(1)</script>')).toBe('&lt;script&gt;alert(1)&lt;/script&gt;');
    const html = renderMarkdown('hello <img src=x onerror=alert(1)>');
    expect(html).not.toContain('<img');
    expect(html).toContain('&lt;img');
  });

  it('renders common blocks and links', () => {
    const html = renderMarkdown('# Title\n\nA **bold** and _em_ and `code`.\n\n- [x] done\n- item\n\n1. one\n\n```\nconst a = 1;\n```\n\n[site](https://example.com)');
    expect(html).toContain('<h1>Title</h1>');
    expect(html).toContain('<strong>bold</strong>');
    expect(html).toContain('<em>em</em>');
    expect(html).toContain('<code>code</code>');
    expect(html).toContain('checked');
    expect(html).toContain('<ol>');
    expect(html).toContain('<pre><code>');
    expect(html).toContain('href="https://example.com"');
  });

  it('builds a one-line preview without the title', () => {
    expect(plainPreview('# Hello\n\nbody text', 'Hello')).toBe('body text');
  });
});
