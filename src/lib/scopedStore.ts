// Device storage scoped to ONE signed-in account (security review 2026-11-04, H1): every key is
// `plantboard.<userId>.<name>`, so one account on a shared phone or tablet can never read, send or
// clear another account's pending entries, taps, PIN or staff session. Pure except browserBase().

/** The subset of the Web Storage API we use; localStorage in the app, a Map in tests. */
export interface KeyValueStore {
  getItem(key: string): string | null;
  setItem(key: string, value: string): void;
}

export function scopedKey(userId: string, name: string): string {
  return `plantboard.${userId}.${name}`;
}

/** A view of `base` that only sees `userId`'s keys. */
export function scopedStore(base: KeyValueStore, userId: string): KeyValueStore {
  if (!userId) throw new Error('scopedStore needs a user id');
  return {
    getItem: (name) => base.getItem(scopedKey(userId, name)),
    setItem: (name, value) => base.setItem(scopedKey(userId, name), value),
  };
}

/** A Map-backed store for tests and as a fallback when localStorage is unavailable. */
export function memoryStore(): KeyValueStore {
  const map = new Map<string, string>();
  return {
    getItem: (k) => map.get(k) ?? null,
    setItem: (k, v) => {
      map.set(k, v);
    },
  };
}

let base: KeyValueStore | null = null;
let persistent = true;

/** localStorage, falling back to memory for this page's life when the browser refuses. */
export function browserBase(): KeyValueStore {
  if (base) return base;
  const memory = new Map<string, string>();
  base = {
    getItem(k) {
      if (!persistent) return memory.get(k) ?? null;
      try {
        return window.localStorage.getItem(k);
      } catch {
        persistent = false;
        return memory.get(k) ?? null;
      }
    },
    setItem(k, v) {
      memory.set(k, v);
      if (!persistent) return;
      try {
        window.localStorage.setItem(k, v);
      } catch {
        persistent = false;
      }
    },
  };
  return base;
}

/** false = the device can't keep entries across a reload (private mode, quota). */
export function isBrowserStorePersistent(): boolean {
  return persistent;
}

/** The signed-in user's own store. */
export function userStore(userId: string): KeyValueStore {
  return scopedStore(browserBase(), userId);
}
