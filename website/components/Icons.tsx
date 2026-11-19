// Small line icons drawn for this site (24×24, stroke = currentColor).
import type { ReactNode } from "react";

type P = { className?: string };

function Svg({ className, children }: P & { children: ReactNode }) {
  return (
    <svg
      className={className}
      viewBox="0 0 24 24"
      width="24"
      height="24"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.8"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
      focusable="false"
    >
      {children}
    </svg>
  );
}

export const IconSeats = (p: P) => (
  <Svg {...p}>
    <rect x="2.5" y="9" width="5.5" height="5.5" rx="1.6" />
    <rect x="9.25" y="6.5" width="5.5" height="5.5" rx="1.6" />
    <rect x="16" y="9" width="5.5" height="5.5" rx="1.6" />
    <path d="M3 18.5h18" />
  </Svg>
);

export const IconBadge = (p: P) => (
  <Svg {...p}>
    <rect x="3.5" y="3.5" width="17" height="17" rx="4.5" />
    <path d="M10.5 9.5l2-1.5v8" />
    <path d="M3.5 16.5h17" />
  </Svg>
);

export const IconSignIn = (p: P) => (
  <Svg {...p}>
    <path d="M14 4h4a2 2 0 0 1 2 2v12a2 2 0 0 1-2 2h-4" />
    <path d="M10 16.5l4.5-4.5L10 7.5" />
    <path d="M14.5 12H3.5" />
  </Svg>
);

export const IconKey = (p: P) => (
  <Svg {...p}>
    <circle cx="8" cy="15.5" r="4" />
    <path d="M11 12.5l8.5-8.5" />
    <path d="M16.5 7l2.5 2.5" />
    <path d="M14 9.5l2 2" />
  </Svg>
);

export const IconArchive = (p: P) => (
  <Svg {...p}>
    <rect x="3" y="4" width="18" height="5" rx="1.5" />
    <path d="M5 9v9a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V9" />
    <path d="M10 13h4" />
  </Svg>
);

export const IconShield = (p: P) => (
  <Svg {...p}>
    <path d="M12 3l7.5 3v5.5c0 4.6-3.2 8.3-7.5 9.5-4.3-1.2-7.5-4.9-7.5-9.5V6z" />
    <path d="M8.75 12l2.25 2.25 4.25-4.5" />
  </Svg>
);

export const IconPulse = (p: P) => (
  <Svg {...p}>
    <path d="M3 12.5h3.5l2.5-6 4 12 2.5-6H21" />
  </Svg>
);

export const IconMoon = (p: P) => (
  <Svg {...p}>
    <path d="M19.5 14.5A7.5 7.5 0 1 1 9.5 4.5a6 6 0 0 0 10 10z" />
  </Svg>
);

export const IconMacs = (p: P) => (
  <Svg {...p}>
    <rect x="2.5" y="5" width="11" height="8" rx="1.5" />
    <path d="M6 16h4" />
    <rect x="13.5" y="9" width="8" height="6" rx="1.3" />
    <path d="M16 18h3" />
  </Svg>
);

export const IconTerminal = (p: P) => (
  <Svg {...p}>
    <rect x="3" y="4" width="18" height="16" rx="2.5" />
    <path d="M7.5 9.5l3 2.5-3 2.5" />
    <path d="M12.5 15h4" />
  </Svg>
);

export const IconLock = (p: P) => (
  <Svg {...p}>
    <rect x="5" y="10.5" width="14" height="10" rx="2.2" />
    <path d="M8.5 10.5V8a3.5 3.5 0 0 1 7 0v2.5" />
  </Svg>
);

export const IconBolt = (p: P) => (
  <Svg {...p}>
    <path d="M13 2.5L5 13.5h6l-1 8 8-11h-6z" />
  </Svg>
);

export const IconRefresh = (p: P) => (
  <Svg {...p}>
    <path d="M20 11a8 8 0 0 0-14.3-4.5L4 8.5" />
    <path d="M4 4v4.5h4.5" />
    <path d="M4 13a8 8 0 0 0 14.3 4.5l1.7-2" />
    <path d="M20 20v-4.5h-4.5" />
  </Svg>
);

export const IconCheck = (p: P) => (
  <Svg {...p}>
    <path d="M5 12.5l4.5 4.5L19 7.5" />
  </Svg>
);

export const IconDash = (p: P) => (
  <Svg {...p}>
    <path d="M7 12h10" />
  </Svg>
);

export const IconDownload = (p: P) => (
  <Svg {...p}>
    <path d="M12 3.5v12" />
    <path d="M7 11l5 5 5-5" />
    <path d="M4.5 20h15" />
  </Svg>
);

export const IconArrow = (p: P) => (
  <Svg {...p}>
    <path d="M5 12h14" />
    <path d="M13 6l6 6-6 6" />
  </Svg>
);

export const IconMenu = (p: P) => (
  <Svg {...p}>
    <path d="M4 7h16" />
    <path d="M4 12h16" />
    <path d="M4 17h16" />
  </Svg>
);

export const IconCloud = (p: P) => (
  <Svg {...p}>
    <path d="M7 18.5h10.5a4 4 0 0 0 .6-7.95A6 6 0 0 0 6.6 9.1 4.75 4.75 0 0 0 7 18.5z" />
    <path d="M12 16v-5.5" />
    <path d="M9.75 12.5L12 10.25l2.25 2.25" />
  </Svg>
);

/** GitHub mark, used only to label links to the repository. */
export const IconGitHub = ({ className }: P) => (
  <svg className={className} viewBox="0 0 16 16" width="20" height="20" fill="currentColor" aria-hidden="true" focusable="false">
    <path d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27.68 0 1.36.09 2 .27 1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.013 8.013 0 0 0 16 8c0-4.42-3.58-8-8-8z" />
  </svg>
);
