// "12 min ago" / "2 h ago" / "3 days ago" (review 2026-11-09: a clock time with no date makes
// yesterday's value look current after midnight). Pure, for tests; the hook is in useAgo.ts.

export interface AgoParts {
  unit: 'min' | 'hour' | 'day';
  count: number;
}

/** Whole minutes under an hour, whole hours under 48 h, then whole days. A future time reads 0 min. */
export function agoParts(thenMs: number, nowMs: number): AgoParts {
  const min = Math.max(0, Math.floor((nowMs - thenMs) / 60_000));
  if (min < 60) return { unit: 'min', count: min };
  const h = Math.floor(min / 60);
  return h < 48 ? { unit: 'hour', count: h } : { unit: 'day', count: Math.floor(h / 24) };
}
