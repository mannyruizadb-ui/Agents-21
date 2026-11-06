// Pure time math for the washer board and station (no React, no I/O). All inputs are epoch ms or
// ISO strings from the server; the server clock is the reference so a phone with a wrong clock still
// counts down correctly.

/**
 * The server's "now", estimated from the board's server_time plus the time elapsed on this device
 * since the board was fetched. Falls back to the device clock when server_time is missing.
 */
export function estimateServerNow(
  serverTime: string | null | undefined,
  fetchedAtMs: number,
  nowMs: number,
): number {
  if (!serverTime) return nowMs;
  const server = Date.parse(serverTime);
  if (Number.isNaN(server)) return nowMs;
  return server + Math.max(0, nowMs - fetchedAtMs);
}

/** Whole seconds until expectedEndAt (never negative); null when the end time is unknown. */
export function secondsLeft(
  expectedEndAt: string | null | undefined,
  serverNowMs: number,
): number | null {
  if (!expectedEndAt) return null;
  const end = Date.parse(expectedEndAt);
  if (Number.isNaN(end)) return null;
  return Math.max(0, Math.ceil((end - serverNowMs) / 1000));
}

/** Whole minutes since expectedEndAt (0 while still running); null when unknown. */
export function minutesSinceEnd(
  expectedEndAt: string | null | undefined,
  serverNowMs: number,
): number | null {
  if (!expectedEndAt) return null;
  const end = Date.parse(expectedEndAt);
  if (Number.isNaN(end)) return null;
  return Math.max(0, Math.floor((serverNowMs - end) / 60000));
}

/** "7:05" for 425 s, "1:02:03" for an hour or more. */
export function formatCountdown(totalSeconds: number): string {
  const s = Math.max(0, Math.floor(totalSeconds));
  const h = Math.floor(s / 3600);
  const m = Math.floor((s % 3600) / 60);
  const sec = s % 60;
  const ss = String(sec).padStart(2, '0');
  return h > 0 ? `${h}:${String(m).padStart(2, '0')}:${ss}` : `${m}:${ss}`;
}

/** Minutes left, rounded up, for spoken/short text ("6 min left" while 5:01 shows). */
export function minutesLeftRoundedUp(totalSeconds: number): number {
  return Math.ceil(Math.max(0, totalSeconds) / 60);
}

export type WasherStatus = 'idle' | 'running' | 'ready' | 'unknown';

/** The server's status, moved forward on the device: a running cycle whose countdown hit 0 is ready. */
export function liveStatus(
  serverStatus: string | null | undefined,
  left: number | null,
): WasherStatus {
  if (serverStatus === 'running') return left === 0 ? 'ready' : 'running';
  if (serverStatus === 'ready' || serverStatus === 'idle' || serverStatus === 'unknown') {
    return serverStatus;
  }
  return 'unknown';
}

/** Whole seconds since a timestamp (data age); never negative. */
export function ageSeconds(sinceMs: number, nowMs: number): number {
  return Math.max(0, Math.floor((nowMs - sinceMs) / 1000));
}

export type Freshness = 'fresh' | 'stale' | 'old';

/**
 * Data age bands for the "updated X s ago" line. Fresh within two refresh periods; stale up to
 * 5 minutes (shown with a warning icon + text); old beyond that.
 */
export function freshness(age: number, refreshSeconds = 30): Freshness {
  if (age <= refreshSeconds * 2) return 'fresh';
  if (age <= 300) return 'stale';
  return 'old';
}

export interface WasherNow {
  status: WasherStatus;
  /** Seconds left in the running cycle; null when unknown or not running. */
  left: number | null;
  /** Minutes a finished load has been waiting to be unloaded; null unless ready. */
  readyMinutes: number | null;
}

/** Everything the board and station show about a washer's current cycle, at device time `nowMs`. */
export function washerNow(
  serverStatus: string | null | undefined,
  expectedEndAt: string | null | undefined,
  serverTime: string | null | undefined,
  fetchedAtMs: number,
  nowMs: number,
): WasherNow {
  const serverNow = estimateServerNow(serverTime, fetchedAtMs, nowMs);
  const left = serverStatus === 'running' ? secondsLeft(expectedEndAt, serverNow) : null;
  const status = liveStatus(serverStatus, left);
  return {
    status,
    left: status === 'running' ? left : null,
    readyMinutes: status === 'ready' ? minutesSinceEnd(expectedEndAt, serverNow) : null,
  };
}
