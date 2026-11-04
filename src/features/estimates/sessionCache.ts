// "A PIN is good for 10 minutes on that phone" (owner 2026-11-04) = the server's reuse window
// (plants.staff_pin_reuse_minutes): a staff session stays valid until its expires_at. The phone
// remembers the session id (never the PIN), for which account, plant and person, and when it ends,
// and skips the PIN while it lasts. With a window of 0 nothing is cached. The server stays the
// judge: a refused session asks for the PIN again. Pure module; the store is the user's scoped one.

import type { KeyValueStore } from '../../lib/scopedStore';

export interface CachedSession {
  /** The signed-in account that opened it (security L1). */
  userId: string;
  plantId: string;
  staffId: string;
  sessionId: string;
  /** Epoch ms when the server's window ends. */
  expiresAt: number;
}

export const SESSION_KEY = 'staffSession.v1';
/** Treat a session as gone this long before its end, so a save never races the expiry. */
const MARGIN_MS = 20_000;

export function readSession(store: KeyValueStore): CachedSession | null {
  try {
    const raw = store.getItem(SESSION_KEY);
    if (!raw) return null;
    const v = JSON.parse(raw) as Partial<CachedSession>;
    return typeof v.userId === 'string' &&
      typeof v.plantId === 'string' &&
      typeof v.staffId === 'string' &&
      typeof v.sessionId === 'string' &&
      typeof v.expiresAt === 'number'
      ? (v as CachedSession)
      : null;
  } catch {
    return null;
  }
}

export interface SessionMatch {
  userId: string;
  plantId: string;
  /** Only this person's session; null/undefined = anyone's. */
  staffId?: string | null;
}

/** The cached session if it is still inside the window and matches account, plant and person. */
export function validSession(
  c: CachedSession | null,
  nowMs: number,
  match: SessionMatch,
): CachedSession | null {
  if (!c || c.expiresAt - MARGIN_MS <= nowMs) return null;
  if (c.userId !== match.userId || c.plantId !== match.plantId) return null;
  if (match.staffId && c.staffId !== match.staffId) return null;
  return c;
}

/** Remembers a session until `expiresAtMs` (the server's expires_at). */
export function rememberSession(store: KeyValueStore, session: CachedSession): void {
  try {
    store.setItem(SESSION_KEY, JSON.stringify(session));
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

/**
 * When a session ends: the server's expires_at when it gives one; otherwise opened-at + the plant's
 * reuse window. 0 minutes (single-use sessions) → null, nothing is cached.
 */
export function sessionEnd(
  serverExpiresAt: string | null | undefined,
  openedAtMs: number,
  reuseMinutes: number,
): number | null {
  if (reuseMinutes <= 0) return null;
  const server = serverExpiresAt ? Date.parse(serverExpiresAt) : NaN;
  return Number.isNaN(server) ? openedAtMs + reuseMinutes * 60_000 : server;
}
