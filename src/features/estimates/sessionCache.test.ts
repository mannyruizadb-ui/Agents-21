import { describe, expect, it } from 'vitest';
import { memoryStore } from '../../lib/scopedStore';
import {
  forgetSession,
  readSession,
  rememberSession,
  sessionEnd,
  validSession,
  type CachedSession,
} from './sessionCache';

const session: CachedSession = {
  userId: 'u1',
  plantId: 'p1',
  staffId: 'staff1',
  sessionId: 'sess1',
  expiresAt: 600_000,
};
const me = { userId: 'u1', plantId: 'p1' };

describe('staff session cache', () => {
  it('keeps a session for the server window, minus a safety margin', () => {
    const s = memoryStore();
    rememberSession(s, session);
    const c = readSession(s);
    expect(c).toEqual(session);
    expect(validSession(c, 500_000, me)).not.toBeNull();
    expect(validSession(c, 590_000, me)).toBeNull();
    expect(validSession(c, 100, { ...me, staffId: 'someone-else' })).toBeNull();
    expect(validSession(c, 100, { ...me, staffId: 'staff1' })).not.toBeNull();
  });
  it('security L1: a different account or plant gets nothing', () => {
    expect(validSession(session, 100, { userId: 'u2', plantId: 'p1' })).toBeNull();
    expect(validSession(session, 100, { userId: 'u1', plantId: 'p2' })).toBeNull();
  });
  it("uses the server's expires_at, else opened-at + window, and caches nothing at 0", () => {
    expect(sessionEnd('1970-01-01T00:10:00Z', 0, 10)).toBe(600_000);
    expect(sessionEnd(null, 1000, 10)).toBe(601_000);
    expect(sessionEnd('1970-01-01T00:10:00Z', 0, 0)).toBeNull();
  });
  it('forgets and survives junk (and old entries without user/plant)', () => {
    const s = memoryStore();
    rememberSession(s, session);
    forgetSession(s);
    expect(readSession(s)).toBeNull();
    s.setItem('staffSession.v1', JSON.stringify({ staffId: 'a', sessionId: 'b', expiresAt: 1 }));
    expect(readSession(s)).toBeNull();
  });
});
