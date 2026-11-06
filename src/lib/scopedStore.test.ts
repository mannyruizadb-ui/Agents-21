import { describe, expect, it } from 'vitest';
import { memoryStore, scopedKey, scopedStore } from './scopedStore';

describe('scopedStore', () => {
  it('prefixes every key with the user id and hides other users', () => {
    const base = memoryStore();
    const a = scopedStore(base, 'userA');
    const b = scopedStore(base, 'userB');
    a.setItem('estimates.outbox.v1', 'A-data');
    expect(base.getItem('plantboard.userA.estimates.outbox.v1')).toBe('A-data');
    expect(b.getItem('estimates.outbox.v1')).toBeNull();
    expect(scopedKey('u', 'x')).toBe('plantboard.u.x');
  });
  it('refuses an empty user id', () => {
    expect(() => scopedStore(memoryStore(), '')).toThrow();
  });
});
