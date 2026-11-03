// The language chosen on this device (before or after sign-in), remembered in localStorage.
// Storage can be missing or throw (private mode, blocked site data), so every access is guarded
// and the app works without it.

export const LANGUAGE_STORAGE_KEY = 'plantboard.language';

type StorageLike = Pick<Storage, 'getItem' | 'setItem'>;

function defaultStorage(): StorageLike | null {
  try {
    return globalThis.localStorage ?? null;
  } catch {
    return null;
  }
}

export function readRememberedLanguage(
  available: readonly string[],
  storage: StorageLike | null = defaultStorage(),
): string | null {
  try {
    const value = storage?.getItem(LANGUAGE_STORAGE_KEY) ?? null;
    return value !== null && available.includes(value) ? value : null;
  } catch {
    return null;
  }
}

export function rememberLanguage(
  code: string,
  storage: StorageLike | null = defaultStorage(),
): void {
  try {
    storage?.setItem(LANGUAGE_STORAGE_KEY, code);
  } catch {
    // Not remembered on this device; the choice still applies to this visit.
  }
}

/**
 * The language's own name ("English", "Español"), from the platform, so no language list is
 * hard-coded (PRD H1). Falls back to the code.
 */
export function languageNativeName(code: string): string {
  try {
    const name = new Intl.DisplayNames([code], { type: 'language' }).of(code);
    if (!name || name === code) return code;
    return name.charAt(0).toLocaleUpperCase(code) + name.slice(1);
  } catch {
    return code;
  }
}
