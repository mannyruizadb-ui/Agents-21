// Small inline SVG icons (no icon library: no new dependencies). Always decorative: every icon sits
// next to visible text that carries the meaning (never color or icon alone).

interface IconProps {
  size?: number | string;
  className?: string;
}

function Svg({ size = '1.25em', className, children }: IconProps & { children: React.ReactNode }) {
  return (
    <svg
      className={className ? `icon ${className}` : 'icon'}
      width={size}
      height={size}
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth={2.5}
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
      focusable="false"
    >
      {children}
    </svg>
  );
}

/** Running: a spinning drum (circle with a sweep). */
export const IconRunning = (p: IconProps) => (
  <Svg {...p}>
    <circle cx="12" cy="12" r="9" />
    <path d="M12 3a9 9 0 0 1 9 9" />
    <path d="M12 7v5l3 2" />
  </Svg>
);

/** Ready to unload: check mark in a circle. */
export const IconReady = (p: IconProps) => (
  <Svg {...p}>
    <circle cx="12" cy="12" r="9" />
    <path d="m8 12 3 3 5-6" />
  </Svg>
);

/** Idle / empty: an empty square. */
export const IconIdle = (p: IconProps) => (
  <Svg {...p}>
    <rect x="4" y="4" width="16" height="16" rx="3" />
  </Svg>
);

/** Unknown / warning: triangle with "!". */
export const IconWarning = (p: IconProps) => (
  <Svg {...p}>
    <path d="M12 3 2 21h20L12 3z" />
    <path d="M12 10v5M12 18h.01" />
  </Svg>
);

/** RUSH: lightning bolt. */
export const IconRush = (p: IconProps) => (
  <Svg {...p}>
    <path d="M13 2 4 14h7l-1 8 9-12h-7l1-8z" fill="currentColor" />
  </Svg>
);

/** Rewash: circular arrows. */
export const IconRewash = (p: IconProps) => (
  <Svg {...p}>
    <path d="M20 11a8 8 0 0 0-14-5L4 8" />
    <path d="M4 3v5h5" />
    <path d="M4 13a8 8 0 0 0 14 5l2-2" />
    <path d="M20 21v-5h-5" />
  </Svg>
);

/** Assigned to a washer: a pin. */
export const IconPin = (p: IconProps) => (
  <Svg {...p}>
    <path d="M12 22s7-7 7-12a7 7 0 0 0-14 0c0 5 7 12 7 12z" />
    <circle cx="12" cy="10" r="2.5" />
  </Svg>
);

/** Offline / waiting to send: cloud with a slash. */
export const IconOffline = (p: IconProps) => (
  <Svg {...p}>
    <path d="M7 18h10a4 4 0 0 0 .5-8A6 6 0 0 0 6 9a4.5 4.5 0 0 0 1 9z" />
    <path d="m3 3 18 18" />
  </Svg>
);

export const IconUp = (p: IconProps) => (
  <Svg {...p}>
    <path d="m6 15 6-6 6 6" />
  </Svg>
);

export const IconDown = (p: IconProps) => (
  <Svg {...p}>
    <path d="m6 9 6 6 6-6" />
  </Svg>
);

/** Start: a play triangle. */
export const IconStart = (p: IconProps) => (
  <Svg {...p}>
    <path d="M7 4v16l13-8L7 4z" fill="currentColor" />
  </Svg>
);
