import { classifySignInResponse, invokeSignIn, type SignInResult } from './signInApi';

// Shared plant iPad (owner 2026-11-10). The owner marks ONE device as the plant iPad (Setup → Plant
// iPad); the server returns a random device token once and this device keeps it. On that device the
// sign-in screen lists the plant's managers and leads; a person taps their name and types their own
// 6-digit password (the same lockout and pepper as any sign-in). Owners always use the normal sign-in.
// Anyone signed in on the device is signed out after 10 minutes without use.
//
// The token lives in this browser's storage only. It is not a password: it only shows the names and
// lets the normal password check run for a listed person. The owner can remove the device at any time.

const DEVICE_KEY = 'plantboard.sharedDevice';
const ACTIVE_KEY = 'plantboard.sharedDevice.lastActive';
const IDLE_FLAG_KEY = 'plantboard.sharedDevice.idleSignedOut';
const WHO_KEY = 'plantboard.sharedDevice.who';
const WAITING_KEY = 'plantboard.sharedDevice.waiting';
/** Fired on this window when the device is marked or unmarked (the idle hook re-arms). */
export const SHARED_DEVICE_EVENT = 'plantboard-shared-device';

function changed(): void {
  try {
    window.dispatchEvent(new Event(SHARED_DEVICE_EVENT));
  } catch {
    // no window (tests)
  }
}

/** Owner 2026-11-10: sign out after 10 minutes without use. */
export const IDLE_SIGN_OUT_MS = 10 * 60_000;

export interface SharedDevice {
  id: string;
  token: string;
  label: string;
}

export interface DevicePerson {
  id: string;
  name: string;
}

const TOKEN = /^[0-9a-f]{64}$/;

/** Pure: a stored value → the device, or null when it is missing or malformed. */
export function parseSharedDevice(raw: string | null): SharedDevice | null {
  if (!raw) return null;
  try {
    const v = JSON.parse(raw) as Partial<SharedDevice> | null;
    if (
      v &&
      typeof v.id === 'string' &&
      typeof v.token === 'string' &&
      TOKEN.test(v.token) &&
      typeof v.label === 'string'
    ) {
      return { id: v.id, token: v.token, label: v.label };
    }
  } catch {
    // malformed: treated as not a shared device
  }
  return null;
}

export function readSharedDevice(): SharedDevice | null {
  try {
    return parseSharedDevice(localStorage.getItem(DEVICE_KEY));
  } catch {
    return null;
  }
}

/** Returns false when this browser can't keep it (private mode, storage blocked). */
export function saveSharedDevice(d: SharedDevice): boolean {
  try {
    localStorage.setItem(DEVICE_KEY, JSON.stringify(d));
    const ok = readSharedDevice()?.token === d.token;
    if (ok) changed();
    return ok;
  } catch {
    return false;
  }
}

export function clearSharedDevice(): void {
  try {
    localStorage.removeItem(DEVICE_KEY);
    localStorage.removeItem(ACTIVE_KEY);
    localStorage.removeItem(WHO_KEY);
    localStorage.removeItem(WAITING_KEY);
  } catch {
    // nothing kept
  }
  changed();
}

export function isSharedDevice(): boolean {
  return readSharedDevice() !== null;
}

// ── Idle sign-out bookkeeping ────────────────────────────────────────────────

export function readLastActive(): number | null {
  try {
    const n = Number(localStorage.getItem(ACTIVE_KEY));
    return Number.isFinite(n) && n > 0 ? n : null;
  } catch {
    return null;
  }
}

export function writeLastActive(at: number): void {
  try {
    localStorage.setItem(ACTIVE_KEY, String(at));
  } catch {
    // the in-memory timer still works
  }
}

/** Pure: has the device been unused for the idle limit? */
export function isIdle(
  lastActive: number | null,
  now: number,
  limitMs = IDLE_SIGN_OUT_MS,
): boolean {
  return lastActive !== null && now - lastActive >= limitMs;
}

/** Marks that the last sign-out was the idle one, so the sign-in screen can say why. */
export function markIdleSignOut(): void {
  try {
    sessionStorage.setItem(IDLE_FLAG_KEY, '1');
  } catch {
    // only the message is lost
  }
}

/** Reads and clears the idle sign-out mark. */
export function takeIdleSignOut(): boolean {
  try {
    const v = sessionStorage.getItem(IDLE_FLAG_KEY) === '1';
    sessionStorage.removeItem(IDLE_FLAG_KEY);
    return v;
  } catch {
    return false;
  }
}

// ── Who is signed in, and what an idle sign-out left unsent ────────────────
// Security review M2: an idle sign-out sends what it can first; anything that still can't send stays
// in that person's own storage on this device and goes when they sign in here again. The name screen
// says so, so it isn't forgotten (a washer tap older than 30 minutes is refused by the server).

export interface WaitingNotice {
  name: string;
  count: number;
}

/** The name of whoever signs in on this device (shown in a "waiting to send" notice later). */
export function rememberWho(name: string): void {
  try {
    localStorage.setItem(WHO_KEY, name.slice(0, 80));
  } catch {
    // only the notice's name is lost
  }
}

export function readWho(): string | null {
  try {
    return localStorage.getItem(WHO_KEY);
  } catch {
    return null;
  }
}

/** Pure: the notices after `name` left `count` unsent (0 clears theirs). */
export function withWaiting(list: WaitingNotice[], name: string, count: number): WaitingNotice[] {
  const rest = list.filter((w) => w.name !== name);
  return count > 0 ? [...rest, { name, count }] : rest;
}

export function readWaiting(): WaitingNotice[] {
  try {
    const v = JSON.parse(localStorage.getItem(WAITING_KEY) ?? '[]') as unknown;
    return Array.isArray(v)
      ? v.filter(
          (w): w is WaitingNotice =>
            w !== null &&
            typeof w === 'object' &&
            typeof (w as WaitingNotice).name === 'string' &&
            typeof (w as WaitingNotice).count === 'number',
        )
      : [];
  } catch {
    return [];
  }
}

export function setWaiting(name: string, count: number): void {
  try {
    localStorage.setItem(WAITING_KEY, JSON.stringify(withWaiting(readWaiting(), name, count)));
  } catch {
    // only the notice is lost; the entries themselves are kept
  }
}

// ── Sign-in function calls ───────────────────────────────────────────────────

/** Pure: the people in a `{people: [...]}` response, sorted by name in the user's language. */
export function parsePeople(body: unknown, lang: string): DevicePerson[] | null {
  const list = (body as { people?: unknown } | null)?.people;
  if (!Array.isArray(list)) return null;
  const people = list.filter(
    (p): p is DevicePerson =>
      p !== null &&
      typeof p === 'object' &&
      typeof (p as DevicePerson).id === 'string' &&
      typeof (p as DevicePerson).name === 'string',
  );
  const collator = new Intl.Collator(lang, { sensitivity: 'base' });
  return [...people].sort((a, b) => collator.compare(a.name, b.name));
}

export async function fetchDevicePeople(token: string, lang: string): Promise<DevicePerson[]> {
  const r = await invokeSignIn({ device_token: token });
  const people = r?.status === 200 ? parsePeople(r.body, lang) : null;
  if (people === null) throw new Error('people');
  return people;
}

export async function deviceSignIn(
  token: string,
  memberId: string,
  password: string,
): Promise<SignInResult> {
  const r = await invokeSignIn({ device_token: token, member_id: memberId, password });
  return r === null ? { kind: 'failed' } : classifySignInResponse(r.status, r.body);
}
