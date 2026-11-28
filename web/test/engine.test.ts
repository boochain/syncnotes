import { describe, expect, it } from 'vitest';
import { SyncEngine } from '../src/sync/engine';
import { isCompleted, isViewed, type Block } from '../src/protocol/types';
import { dashboardProgress, isDashboardBlock } from '../src/features/dashboard';

function engine(): SyncEngine {
  const e = new SyncEngine('device-web');
  e.markOnlineForTests();
  return e;
}

function serverBlock(partial: Partial<Block> & Pick<Block, 'id'>): Record<string, unknown> {
  return {
    id: partial.id,
    kind: partial.kind ?? 'note',
    title: partial.title ?? 't',
    payload: partial.payload ?? { markdown: 'hi' },
    parent_id: partial.parent_id ?? null,
    viewed_mode: partial.viewed_mode ?? 'per_device',
    viewed_global: partial.viewed_global ?? false,
    created_at: partial.created_at ?? 1,
    updated_at: partial.updated_at ?? 1,
    created_by: partial.created_by ?? 'other',
    deleted: partial.deleted ?? false,
    deleted_at: partial.deleted_at ?? null,
    deleted_by: partial.deleted_by ?? null,
    seq: partial.seq ?? 1,
  };
}

describe('SyncEngine', () => {
  it('creates an optimistic note and queues an upsert', () => {
    const e = engine();
    const b = e.create({ kind: 'note', title: 'hello', payload: { markdown: '# hi' } });
    expect(b.pending).toBe(true);
    expect(e.pendingCount).toBe(1);
    expect(e.visible().map((x) => x.id)).toEqual([b.id]);
  });

  it('moves a block to trash and restores it, including orphaned parent handling', () => {
    const e = engine();
    const folder = e.create({ kind: 'folder', title: '箱' });
    const note = e.create({ kind: 'note', title: 'n', parentId: folder.id, payload: { markdown: 'x' } });
    expect(e.childrenOf(folder.id)).toHaveLength(1);
    e.delete(folder.id);
    expect(e.visible()).toHaveLength(0);
    expect(e.trash.map((b) => b.id)).toEqual([folder.id]);
    expect(e.trashChildCount(folder.id)).toBe(1);
    // Children stay attached: restoring the folder brings them back.
    e.restoreAll([folder.id]);
    expect(e.childrenOf(folder.id).map((b) => b.id)).toEqual([note.id]);
    // If the child itself is binned and its parent is also gone, it returns to root.
    e.delete(note.id);
    e.delete(folder.id);
    const toRoot = e.restoreAll([note.id]);
    expect(toRoot).toEqual([note.id]);
    expect(e.byId(note.id)?.parent_id).toBeNull();
    expect(e.visible().some((b) => b.id === note.id)).toBe(true);
  });

  it('purge marks a tree as permanently deleted', () => {
    const e = engine();
    const folder = e.create({ kind: 'folder', title: 'f' });
    e.create({ kind: 'message', title: 'm', parentId: folder.id, payload: { text: 'a' } });
    e.delete(folder.id);
    e.purge([folder.id]);
    expect(e.trash).toHaveLength(0);
    expect(e.byId(folder.id)?.deleted).toBe(true);
    expect(e.visible()).toHaveLength(0);
  });

  it('applies LWW: a newer local pending edit is not overwritten', () => {
    const e = engine();
    const b = e.create({ kind: 'note', title: 'local', payload: { markdown: 'A' } });
    e.update(b.id, { title: 'newer', payload: { markdown: 'B' } });
    const local = e.byId(b.id)!;
    e.applyServerMessage({
      type: 'block_update',
      block: serverBlock({
        id: b.id,
        title: 'older',
        payload: { markdown: 'old' },
        updated_at: local.updated_at - 10,
        seq: 9,
        created_by: 'device-web',
      }),
    });
    expect(e.byId(b.id)?.title).toBe('newer');
    e.applyServerMessage({
      type: 'block_update',
      block: serverBlock({
        id: b.id,
        title: 'server-wins',
        payload: { markdown: 'C' },
        updated_at: local.updated_at + 10,
        seq: 10,
      }),
    });
    expect(e.byId(b.id)?.title).toBe('server-wins');
    expect(e.latestSeq).toBe(10);
  });

  it('hides text blocks from the inbox and tracks viewed state', () => {
    const e = engine();
    const page = e.create({ kind: 'page', title: 'P' });
    e.create({ kind: 'text', title: '', parentId: page.id, payload: { type: 'paragraph', text: 'x', order: 1 } });
    expect(e.childrenOf(null).map((b) => b.kind)).toEqual(['page']);
    expect(e.childrenOf(page.id)).toHaveLength(0);
    expect(e.visible().filter((b) => b.kind === 'text')).toHaveLength(1);
    const id = page.id;
    expect(isViewed(e.byId(id)!)).toBe(true);
    e.setViewed(id, false);
    expect(isViewed(e.byId(id)!)).toBe(false);
    e.applyServerMessage({ type: 'viewed_update', block_id: id, viewed: true, device_id: 'device-web', seq: 3 });
    expect(isViewed(e.byId(id)!)).toBe(true);
  });

  it('completes auth handshake by requesting sync_since and dropping confirmed upserts', () => {
    const e = engine();
    e.applyServerMessage({ type: 'auth_ok', user_id: 'u', username: 'bill' });
    e.applyServerMessage({
      type: 'block_update',
      block: serverBlock({ id: 'n1', title: 'from-server', seq: 4, updated_at: 40 }),
    });
    e.applyServerMessage({ type: 'sync_complete', latest_seq: 4 });
    expect(e.connState).toBe('online');
    expect(e.byId('n1')?.title).toBe('from-server');
    expect(e.latestSeq).toBe(4);
  });
});

describe('dashboard reservation', () => {
  it('reads weighted step progress without inventing a write schema', () => {
    const b = {
      id: 't1',
      kind: 'dashboard_task',
      title: 'demo',
      payload: {
        steps: [
          { id: 'a', title: '设计', weight: 2, done: true },
          { id: 'b', title: '实现', weight: 2, done: false },
        ],
      },
      parent_id: null,
      viewed_mode: 'per_device',
      viewed_global: false,
      created_at: 1,
      updated_at: 1,
      created_by: 'x',
      deleted: false,
      deleted_at: null,
      deleted_by: null,
      seq: 0,
      viewed_local: true,
      pending: false,
    } satisfies Block;
    expect(isDashboardBlock(b)).toBe(true);
    expect(dashboardProgress(b)).toBe(0.5);
    expect(isCompleted(b)).toBe(false);
  });
});
