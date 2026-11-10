import { describe, expect, it, vi } from 'vitest';

vi.mock('../../lib/supabase', () => ({ supabase: {} }));
import {
  IDLE_SIGN_OUT_MS,
  isIdle,
  parsePeople,
  parseSharedDevice,
  withWaiting,
} from './sharedDevice';

const TOKEN = 'ab'.repeat(32);

describe('parseSharedDevice', () => {
  it('reads a stored device', () => {
    expect(
      parseSharedDevice(JSON.stringify({ id: 'd1', token: TOKEN, label: 'Plant iPad' })),
    ).toEqual({
      id: 'd1',
      token: TOKEN,
      label: 'Plant iPad',
    });
  });
  it('treats missing or malformed values as not a shared device', () => {
    for (const raw of [
      null,
      '',
      'not json',
      'null',
      JSON.stringify({ id: 'd1', token: 'short', label: 'x' }),
      JSON.stringify({ id: 'd1', token: TOKEN.toUpperCase(), label: 'x' }),
      JSON.stringify({ token: TOKEN, label: 'x' }),
    ]) {
      expect(parseSharedDevice(raw)).toBeNull();
    }
  });
});

describe('isIdle', () => {
  it('is 10 minutes', () => {
    expect(IDLE_SIGN_OUT_MS).toBe(600_000);
  });
  it('signs out at the limit, not before', () => {
    expect(isIdle(1_000, 1_000 + IDLE_SIGN_OUT_MS - 1)).toBe(false);
    expect(isIdle(1_000, 1_000 + IDLE_SIGN_OUT_MS)).toBe(true);
  });
  it('never signs out without a recorded activity', () => {
    expect(isIdle(null, Date.now())).toBe(false);
  });
});

describe('parsePeople', () => {
  it('keeps well-formed people, sorted by name ignoring case and accents', () => {
    const body = {
      people: [
        { id: '2', name: 'yasmary' },
        { id: '1', name: 'Denise' },
        { id: '3', name: 'Ángel' },
        { id: 4, name: 'bad id' },
        null,
      ],
    };
    expect(parsePeople(body, 'es')?.map((p) => p.name)).toEqual(['Ángel', 'Denise', 'yasmary']);
  });
  it('returns null for a body that is not a list of people', () => {
    expect(parsePeople(null, 'en')).toBeNull();
    expect(parsePeople({ code: 'INTERNAL' }, 'en')).toBeNull();
  });
});

describe('withWaiting', () => {
  it('keeps one notice per person and clears it at 0', () => {
    let list = withWaiting([], 'Denise', 3);
    list = withWaiting(list, 'Yasmary', 1);
    list = withWaiting(list, 'Denise', 2);
    expect(list).toEqual([
      { name: 'Yasmary', count: 1 },
      { name: 'Denise', count: 2 },
    ]);
    expect(withWaiting(list, 'Yasmary', 0)).toEqual([{ name: 'Denise', count: 2 }]);
  });
});
