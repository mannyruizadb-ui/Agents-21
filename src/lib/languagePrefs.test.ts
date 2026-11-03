import { describe, expect, it } from 'vitest';
import {
  languageNativeName,
  LANGUAGE_STORAGE_KEY,
  readRememberedLanguage,
  rememberLanguage,
} from './languagePrefs';

function memoryStorage() {
  const map = new Map<string, string>();
  return {
    getItem: (k: string) => map.get(k) ?? null,
    setItem: (k: string, v: string) => void map.set(k, v),
  };
}
const throwing = {
  getItem: () => {
    throw new Error('blocked');
  },
  setItem: () => {
    throw new Error('blocked');
  },
};

describe('language preference on this device', () => {
  it('remembers and reads back an available language', () => {
    const s = memoryStorage();
    rememberLanguage('es', s);
    expect(s.getItem(LANGUAGE_STORAGE_KEY)).toBe('es');
    expect(readRememberedLanguage(['en', 'es'], s)).toBe('es');
  });

  it('ignores a remembered language whose locale file is gone', () => {
    const s = memoryStorage();
    rememberLanguage('ht', s);
    expect(readRememberedLanguage(['en', 'es'], s)).toBeNull();
  });

  it('never throws when storage is blocked or missing', () => {
    expect(() => rememberLanguage('es', throwing)).not.toThrow();
    expect(readRememberedLanguage(['en', 'es'], throwing)).toBeNull();
    expect(readRememberedLanguage(['en', 'es'], null)).toBeNull();
  });

  it('names each language in itself', () => {
    expect(languageNativeName('en')).toBe('English');
    expect(languageNativeName('es')).toBe('Español');
    expect(languageNativeName('zz-not-a-code!')).toBe('zz-not-a-code!');
  });
});
