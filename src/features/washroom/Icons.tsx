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

/** Machine down: a wrench. */
export const IconMachineDown = (p: IconProps) => (
  <Svg {...p}>
    <path d="M14.7 6.3a4 4 0 0 0-5.4 5.4L3 18l3 3 6.3-6.3a4 4 0 0 0 5.4-5.4l-2.6 2.6-2.4-.6-.6-2.4 2.6-2.6z" />
  </Svg>
);

/* Bottom-nav icons. */
export const IconWasher = (p: IconProps) => (
  <Svg {...p}>
    <rect x="4" y="3" width="16" height="18" rx="2" />
    <circle cx="12" cy="13" r="4.5" />
    <path d="M7 6.5h2" />
  </Svg>
);
export const IconQueue = (p: IconProps) => (
  <Svg {...p}>
    <path d="M9 6h11M9 12h11M9 18h11" />
    <path d="M4 6h1M4 12h1M4 18h1" />
  </Svg>
);
export const IconTruck = (p: IconProps) => (
  <Svg {...p}>
    <path d="M3 6h11v10H3zM14 10h4l3 3v3h-7z" />
    <circle cx="7" cy="18" r="1.8" />
    <circle cx="17" cy="18" r="1.8" />
  </Svg>
);
export const IconBell = (p: IconProps) => (
  <Svg {...p}>
    <path d="M6 16V11a6 6 0 0 1 12 0v5l2 2H4z" />
    <path d="M10 20a2 2 0 0 0 4 0" />
  </Svg>
);
export const IconMenu = (p: IconProps) => (
  <Svg {...p}>
    <path d="M4 6h16M4 12h16M4 18h16" />
  </Svg>
);
export const IconBins = (p: IconProps) => (
  <Svg {...p}>
    <path d="M5 8h14l-1.5 12h-11z" />
    <path d="M4 5h16v3H4z" />
  </Svg>
);
export const IconTasks = (p: IconProps) => (
  <Svg {...p}>
    <rect x="4" y="3" width="16" height="18" rx="2" />
    <path d="m8 9 2 2 4-4M8 16h8" />
  </Svg>
);
export const IconHome = (p: IconProps) => (
  <Svg {...p}>
    <path d="M3 11 12 4l9 7" />
    <path d="M5 10v10h5v-6h4v6h5V10" />
  </Svg>
);
export const IconGear = (p: IconProps) => (
  <Svg {...p}>
    <circle cx="12" cy="12" r="3" />
    <path d="M12 2v3M12 19v3M4.9 4.9l2.1 2.1M17 17l2.1 2.1M2 12h3M19 12h3M4.9 19.1 7 17M17 7l2.1-2.1" />
  </Svg>
);
export const IconPeople = (p: IconProps) => (
  <Svg {...p}>
    <circle cx="9" cy="8" r="3.5" />
    <path d="M2.5 20a6.5 6.5 0 0 1 13 0" />
    <path d="M16 4.5a3.5 3.5 0 0 1 0 7M18 14a6.5 6.5 0 0 1 3.5 6" />
  </Svg>
);
export const IconEdit = (p: IconProps) => (
  <Svg {...p}>
    <path d="M4 20h4L19 9l-4-4L4 16z" />
    <path d="m13 7 4 4" />
  </Svg>
);
export const IconList = (p: IconProps) => (
  <Svg {...p}>
    <rect x="4" y="3" width="16" height="18" rx="2" />
    <path d="M8 8h8M8 12h8M8 16h5" />
  </Svg>
);
