import type { ReactNode, SVGProps } from 'react';

type P = SVGProps<SVGSVGElement> & { size?: number };

function I({ size = 18, children, ...rest }: P & { children: ReactNode }) {
  return (
    <svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" aria-hidden {...rest}>
      {children}
    </svg>
  );
}

export const Icons = {
  search: (p: P) => <I {...p}><circle cx="11" cy="11" r="6.5"/><path d="M16.5 16.5L21 21"/></I>,
  settings: (p: P) => <I {...p}><circle cx="12" cy="12" r="3"/><path d="M12 3.5v2M12 18.5v2M4.9 6.5l1.5 1.5M17.6 16l1.5 1.5M3.5 12h2M18.5 12h2M4.9 17.5l1.5-1.5M17.6 8l1.5-1.5"/></I>,
  plus: (p: P) => <I {...p}><path d="M12 5v14M5 12h14"/></I>,
  back: (p: P) => <I {...p}><path d="M15 5l-7 7 7 7"/></I>,
  close: (p: P) => <I {...p}><path d="M6 6l12 12M18 6L6 18"/></I>,
  message: (p: P) => <I {...p}><path d="M5 6h14a2 2 0 0 1 2 2v7a2 2 0 0 1-2 2H9l-4 3V8a2 2 0 0 1 2-2z"/></I>,
  note: (p: P) => <I {...p}><path d="M7 4h7l5 5v11a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6a2 2 0 0 1 2-2z"/><path d="M14 4v5h5"/></I>,
  file: (p: P) => <I {...p}><path d="M7 3h7l5 5v13a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2z"/><path d="M14 3v5h5"/></I>,
  folder: (p: P) => <I {...p}><path d="M3 7h6l2 2h10v10a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V7z"/></I>,
  page: (p: P) => <I {...p}><path d="M7 3h8l4 4v14H7z"/><path d="M15 3v4h4M9 12h6M9 16h4"/></I>,
  trash: (p: P) => <I {...p}><path d="M5 7h14M10 7V5h4v2M8 7l1 13h6l1-13"/></I>,
  transfer: (p: P) => <I {...p}><path d="M7 17V7m0 0L4 10M7 7l3 3M17 7v10m0 0l3-3m-3 3-3-3"/></I>,
  check: (p: P) => <I {...p}><path d="M5 12l5 5L20 7"/></I>,
  circle: (p: P) => <I {...p}><circle cx="12" cy="12" r="8"/></I>,
  checkCircle: (p: P) => <I {...p}><circle cx="12" cy="12" r="8"/><path d="M8 12l2.8 2.8L16 9"/></I>,
  list: (p: P) => <I {...p}><path d="M8 7h12M8 12h12M8 17h12M4 7h.01M4 12h.01M4 17h.01"/></I>,
  canvas: (p: P) => <I {...p}><rect x="4" y="5" width="7" height="6" rx="1.5"/><rect x="13" y="8" width="7" height="8" rx="1.5"/><rect x="6" y="14" width="6" height="5" rx="1.5"/></I>,
  arrange: (p: P) => <I {...p}><path d="M5 7h14M5 12h10M5 17h7"/></I>,
  more: (p: P) => <I {...p}><circle cx="6" cy="12" r="1.2" fill="currentColor" stroke="none"/><circle cx="12" cy="12" r="1.2" fill="currentColor" stroke="none"/><circle cx="18" cy="12" r="1.2" fill="currentColor" stroke="none"/></I>,
  copy: (p: P) => <I {...p}><rect x="8" y="8" width="11" height="11" rx="2"/><path d="M5 15V5h10"/></I>,
  download: (p: P) => <I {...p}><path d="M12 4v12m0 0l-4-4m4 4 4-4M5 20h14"/></I>,
  logout: (p: P) => <I {...p}><path d="M10 5H6a2 2 0 0 0-2 2v10a2 2 0 0 0 2 2h4M14 12h8m0 0-3-3m3 3-3 3"/></I>,
  sun: (p: P) => <I {...p}><circle cx="12" cy="12" r="4"/><path d="M12 3v2M12 19v2M4.2 4.2l1.4 1.4M18.4 18.4l1.4 1.4M3 12h2M19 12h2M4.2 19.8l1.4-1.4M18.4 5.6l1.4-1.4"/></I>,
  moon: (p: P) => <I {...p}><path d="M16 3a8 8 0 1 0 5 13 7 7 0 0 1-5-13z"/></I>,
  task: (p: P) => <I {...p}><rect x="4" y="4" width="16" height="16" rx="4"/><path d="M8.5 12l2.5 2.5 4.5-5"/></I>,
  calendar: (p: P) => <I {...p}><rect x="4" y="5" width="16" height="15" rx="2.5"/><path d="M4 10h16M8.5 3v4M15.5 3v4"/></I>,
  restore: (p: P) => <I {...p}><path d="M4 12a8 8 0 1 0 2.3-5.6M4 5v5h5"/></I>,
};

export function KindIcon({ kind, size = 16 }: { kind: string; size?: number }) {
  const P = kind === 'message' ? Icons.message
    : kind === 'note' ? Icons.note
    : kind === 'file' ? Icons.file
    : kind === 'folder' ? Icons.folder
    : kind === 'page' ? Icons.page
    : kind === 'task' ? Icons.task
    : kind === 'calendar' ? Icons.calendar
    : Icons.note;
  return <P size={size} />;
}
