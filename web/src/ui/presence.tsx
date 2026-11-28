import { useEffect, useRef, useState, type ReactNode } from 'react';
import { createPortal } from 'react-dom';

/**
 * v0.8.2 卡片式弹层（与 App 同一套规则）：
 * - 弹层打开时，下层界面先淡出（只剩流动背景），弹层卡片再淡入；关闭时倒放。
 * - 卡片表面不透明，任何一帧都不会让下层文字和卡片内容叠在一起。
 * 时长：下层淡出 / 淡入 140ms，卡片进入 300ms（延迟 140ms），退出 200ms。
 */
export const COVER_MS = 140;
export const CARD_OUT_MS = 200;

/** 打开时保持挂载，关闭时先播放退出动画（data-state="out"）再卸载。 */
export function usePresence(open: boolean, exitMs = CARD_OUT_MS) {
  const [mounted, setMounted] = useState(open);
  const [state, setState] = useState<'in' | 'out'>(open ? 'in' : 'out');
  useEffect(() => {
    if (open) {
      setMounted(true);
      setState('in');
      return;
    }
    setState('out');
    const t = setTimeout(() => setMounted(false), exitMs);
    return () => clearTimeout(t);
  }, [open, exitMs]);
  return { mounted: open || mounted, state: open ? ('in' as const) : state };
}

/** 页面卡片层：保留关闭前最后一次的内容，播放完退出动画再卸载。 */
export function CardLayer({ open, onCover, children }: { open: boolean; onCover: (covered: boolean) => void; children: ReactNode }) {
  const { mounted, state } = usePresence(open);
  const last = useRef<ReactNode>(children);
  if (open) last.current = children;
  useEffect(() => { onCover(mounted); }, [mounted, onCover]);
  if (!mounted) return null;
  return (
    <div className="card-layer" data-state={state}>
      {open ? children : last.current}
    </div>
  );
}

let popupCount = 0;
function setPopup(delta: number) {
  popupCount = Math.max(0, popupCount + delta);
  document.documentElement.classList.toggle('popup-open', popupCount > 0);
}

/**
 * 菜单、对话框：挂到 body 上（不在被隐藏的界面里），打开期间整个界面淡出只露背景，
 * 点空白处关闭（由透明的 scrim 接住点击，不会误点到看不见的卡片）。
 */
export function Popup({ open, onClose, children, label }: { open: boolean; onClose?: () => void; children: ReactNode; label?: string }) {
  const { mounted, state } = usePresence(open, 160);
  const last = useRef<ReactNode>(children);
  if (open) last.current = children;
  useEffect(() => {
    if (!mounted) return;
    setPopup(1);
    return () => setPopup(-1);
  }, [mounted]);
  useEffect(() => {
    if (!open || !onClose) return;
    const onKey = (e: KeyboardEvent) => { if (e.key === 'Escape') onClose(); };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [open, onClose]);
  if (!mounted) return null;
  return createPortal(
    <div className="popup-root" data-state={state} aria-label={label}>
      <div className="popup-scrim" onClick={(e) => { e.stopPropagation(); onClose?.(); }} />
      {open ? children : last.current}
    </div>,
    document.body,
  );
}
