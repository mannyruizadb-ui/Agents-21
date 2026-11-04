// "A PIN is good for 10 minutes on that phone" (owner 2026-11-04) = the server's reuse window
// (plants.staff_pin_reuse_minutes): a staff session stays valid until confirmed_at + that window.
// The phone remembers the session id (not the PIN) and its expected end, and skips the PIN while it
// lasts. With a window of 0 nothing is cached: the server spends the session on the first entry.
// The server stays the judge: a refused session asks for the PIN again. Pure module.

import type { KeyValueStore } from '../washroom/tapQueue';

export interface CachedSession {
  staffId: string;
  sessionId: string;
  /** Epoch ms when the server's window ends (estimated from when the session was opened). */
  expiresAt: number;
}

export const SESSION_KEY = 'plantboard.staffSession.v1';
/** Treat a session as gone this long before its end, so a save never races the expiry. */
const MARGIN_MS = 20_000;

export function readSession(store: KeyValueStore): CachedSession | null {
  try {
    const raw = store.getItem(SESSION_KEY);
    if (!raw) return null;
    const v = JSON.parse(raw) as Partial<CachedSession>;
    return typeof v.staffId === 'string' &&
      typeof v.sessionId === 'string' &&
      typeof v.expiresAt === 'number'
      ? (v as CachedSession)
      : null;
  } catch {
    return null;
  }
}

/** The cached session if it is still inside the window (and for `staffId` when given). */
export function validSession(
  c: CachedSession | null,
  nowMs: number,
  staffId?: string | null,
): CachedSession | null {
  if (!c || c.expiresAt - MARGIN_MS <= nowMs) return null;
  if (staffId && c.staffId !== staffId) return null;
  return c;
}

/** Remembers a session opened at `openedAtMs`; nothing is kept when the window is 0. */
export function rememberSession(
  store: KeyValueStore,
  staffId: string,
  sessionId: string,
  openedAtMs: number,
  reuseMinutes: number,
): void {
  try {
    if (reuseMinutes <= 0) {
      store.setItem(SESSION_KEY, '');
      return;
    }
    const value: CachedSession = {
      staffId,
      sessionId,
      expiresAt: openedAtMs + reuseMinutes * 60_000,
    };
    store.setItem(SESSION_KEY, JSON.stringify(value));
  } catch {
    // Storage refused: the PIN is simply asked again next time.
  }
}

export function forgetSession(store: KeyValueStore): void {
  try {
    store.setItem(SESSION_KEY, '');
  } catch {
    // nothing to do
  }
}
