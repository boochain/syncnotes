import { useEffect, useRef } from 'react';
import { mountFluid, type FluidHandle } from '../background/fluid';
import type { GlassQuality } from '../store/session';

export function FluidBackdrop({
  dark,
  refraction,
  quality,
  enabled,
}: {
  dark: boolean;
  refraction: number;
  quality: GlassQuality;
  enabled: boolean;
}) {
  const ref = useRef<HTMLCanvasElement>(null);
  const handle = useRef<FluidHandle | null>(null);
  const reduced = typeof window !== 'undefined' && window.matchMedia?.('(prefers-reduced-motion: reduce)').matches;

  useEffect(() => {
    const canvas = ref.current;
    if (!canvas || !enabled || quality === 'off' || reduced) return;
    try {
      handle.current = mountFluid(canvas);
      handle.current.set({ dark, refraction, quality, running: true });
    } catch {
      handle.current = null;
      canvas.style.display = 'none';
    }
    return () => {
      handle.current?.destroy();
      handle.current = null;
    };
  }, [enabled, quality, reduced]);

  useEffect(() => {
    handle.current?.set({ dark, refraction, quality, running: enabled && quality !== 'off' && !reduced });
    // Drive a visible CSS displacement so the refraction slider always does something,
    // even when WebGL is off.
    document.documentElement.style.setProperty('--refract', String(refraction));
    document.documentElement.style.setProperty('--glass-blur', `${18 + refraction * 22}px`);
  }, [dark, refraction, quality, enabled, reduced]);

  const showFallback = !enabled || quality === 'off' || reduced;
  return (
    <>
      <canvas ref={ref} className="fluid-canvas" style={{ display: showFallback ? 'none' : 'block' }} />
      {showFallback && <div className="fluid-fallback" aria-hidden />}
    </>
  );
}

export function applyChrome(settings: { glassOpacity: number; refraction: number; quality: GlassQuality }) {
  const root = document.documentElement;
  root.style.setProperty('--glass-alpha', String(settings.glassOpacity));
  root.style.setProperty('--refract', String(settings.refraction));
  root.style.setProperty('--glass-blur', `${18 + settings.refraction * 22}px`);
  root.classList.toggle('low-end', settings.quality === 'off' || settings.quality === 'low');
}
