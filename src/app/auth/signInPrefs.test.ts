import { describe, expect, it } from 'vitest';
import { readSignInPrefs, saveSignInPrefs, usesNumberPad } from './signInPrefs';

function mem() {
  const m = new Map<string, string>();
  return {
    getItem: (k: string) => m.get(k) ?? null,
    setItem: (k: string, v: string) => void m.set(k, v),
  };
}

describe('sign-in prefs', () => {
  it('remembers the last username and the keyboard, never more', () => {
    const s = mem();
    expect(readSignInPrefs(s)).toEqual({ lastUsername: '', letters: false });
    saveSignInPrefs({ lastUsername: 'denise', letters: true }, s);
    expect(readSignInPrefs(s)).toEqual({ lastUsername: 'denise', letters: true });
  });
  it('survives junk in storage', () => {
    const s = mem();
    s.setItem('plantboard.signin.v1', '{not json');
    expect(readSignInPrefs(s)).toEqual({ lastUsername: '', letters: false });
  });
  it('shows the number pad except for email sign-ins or on request', () => {
    expect(usesNumberPad('carlos', false)).toBe(true);
    expect(usesNumberPad('owner@gmail.com', false)).toBe(false);
    expect(usesNumberPad('carlos', true)).toBe(false);
  });
});
