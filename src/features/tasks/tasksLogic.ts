// Tasks (owner 2026-11-06): pure helpers. No per-person statistics: nothing here counts, times or ranks
// tasks by person; "open for" is shown per task only.

export const TASK_MAX = 200;

/** Trimmed task text (1–200 characters, no control characters), or null. */
export function cleanTaskText(input: string): string | null {
  const s = input
    // eslint-disable-next-line no-control-regex -- the server refuses control characters
    .replace(/[\u0000-\u001f\u007f]+/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
  return s.length >= 1 && s.length <= TASK_MAX ? s : null;
}

/** Whole minutes between two instants (never negative). */
export function minutesBetween(fromIso: string, nowMs: number): number {
  const t = Date.parse(fromIso);
  return Number.isNaN(t) ? 0 : Math.max(0, Math.floor((nowMs - t) / 60000));
}

/** The server's "nobody on duty" refusal from create_task. */
export function isNobodyOnDuty(detail: string | null | undefined): boolean {
  return !!detail && /no manager is on duty/i.test(detail);
}
