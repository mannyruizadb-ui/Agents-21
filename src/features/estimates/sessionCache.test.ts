import { describe, expect, it } from 'vitest';
import { memoryStore } from '../washroom/tapQueue';
import { forgetSession, readSession, rememberSession, validSession } from './sessionCache';

describe('staff session cache', () => {
  it('keeps a session for the server window, minus a safety margin', () => {
    const s = memoryStore();
    rememberSession(s, 'staff1', 'sess1', 0, 10);
    const c = readSession(s);
    expect(c).toEqual({ staffId: 'staff1', sessionId: 'sess1', expiresAt: 600_000 });
    expect(validSession(c, 500_000)).not.toBeNull();
    expect(validSession(c, 590_000)).toBeNull();
    expect(validSession(c, 100, 'someone-else')).toBeNull();
    expect(validSession(c, 100, 'staff1')).not.toBeNull();
  });
  it('caches nothing when the window is 0 (a PIN on every save)', () => {
    const s = memoryStore();
    rememberSession(s, 'staff1', 'sess1', 0, 0);
    expect(readSession(s)).toBeNull();
  });
  it('forgets and survives junk', () => {
    const s = memoryStore();
    rememberSession(s, 'a', 'b', 0, 10);
    forgetSession(s);
    expect(readSession(s)).toBeNull();
    s.setItem('plantboard.staffSession.v1', '{"staffId":1}');
    expect(readSession(s)).toBeNull();
  });
});
