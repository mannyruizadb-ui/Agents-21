// What the sign-in screen remembers on this phone (owner 2026-11-06): the last username and whether
// that person's password has letters. Never the password. Pure except for the storage calls.

export const SIGN_IN_PREFS_KEY = 'plantboard.signin.v1';

export interface SignInPrefs {
  lastUsername: string;
  letters: boolean;
}

interface Storage {
  getItem(k: string): string | null;
  setItem(k: string, v: string): void;
}

function browserStorage(): Storage | null {
  try {
    return window.localStorage;
  } catch {
    return null;
  }
}

export function readSignInPrefs(store: Storage | null = browserStorage()): SignInPrefs {
  try {
    const raw = store?.getItem(SIGN_IN_PREFS_KEY);
    const v: unknown = raw ? JSON.parse(raw) : null;
    if (v && typeof v === 'object') {
      const o = v as Record<string, unknown>;
      const name = typeof o.lastUsername === 'string' ? o.lastUsername.slice(0, 120) : '';
      return { lastUsername: name, letters: o.letters === true };
    }
  } catch {
    // Unreadable or blocked storage: start empty.
  }
  return { lastUsername: '', letters: false };
}

export function saveSignInPrefs(p: SignInPrefs, store: Storage | null = browserStorage()): void {
  try {
    store?.setItem(SIGN_IN_PREFS_KEY, JSON.stringify(p));
  } catch {
    // Private mode or full storage: nothing to remember, sign-in still works.
  }
}

/** Number pad for managers' 6-digit passwords; the normal keyboard for email sign-ins or on request. */
export function usesNumberPad(username: string, letters: boolean): boolean {
  return !letters && !username.includes('@');
}
