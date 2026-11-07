import { describe, expect, it, vi } from 'vitest';
import { classifySignInResponse, retryMinutes } from './signInApi';

vi.mock('../../lib/supabase', () => ({ supabase: {} }));

describe('classifySignInResponse', () => {
  it('200 with tokens → ok', () => {
    expect(
      classifySignInResponse(200, { access_token: 'a', refresh_token: 'r', user: {} }),
    ).toEqual({ kind: 'ok', accessToken: 'a', refreshToken: 'r' });
  });

  it('200 without tokens → failed', () => {
    expect(classifySignInResponse(200, { access_token: 'a' })).toEqual({ kind: 'failed' });
    expect(classifySignInResponse(200, null)).toEqual({ kind: 'failed' });
  });

  it('401 WRONG and 400 → wrong', () => {
    expect(classifySignInResponse(401, { code: 'WRONG' })).toEqual({ kind: 'wrong' });
    expect(classifySignInResponse(400, { code: 'VALIDATION_FAILED' })).toEqual({ kind: 'wrong' });
  });

  it('429 LOCKED → locked with minutes rounded up', () => {
    expect(classifySignInResponse(429, { code: 'LOCKED', retry_after_seconds: 61 })).toEqual({
      kind: 'locked',
      minutes: 2,
    });
    expect(classifySignInResponse(429, { code: 'LOCKED', retry_after_seconds: 900 })).toEqual({
      kind: 'locked',
      minutes: 15,
    });
  });

  it('429 RATE_LIMITED → rate_limited', () => {
    expect(
      classifySignInResponse(429, { code: 'RATE_LIMITED', retry_after_seconds: 60 }),
    ).toEqual({ kind: 'rate_limited' });
  });

  it('5xx → failed', () => {
    for (const s of [500, 502, 503]) {
      expect(classifySignInResponse(s, { code: 'INTERNAL' })).toEqual({ kind: 'failed' });
    }
  });
});

describe('retryMinutes', () => {
  it('rounds up, at least 1, defaults to 1 minute', () => {
    expect(retryMinutes(1)).toBe(1);
    expect(retryMinutes(60)).toBe(1);
    expect(retryMinutes(119)).toBe(2);
    expect(retryMinutes(0)).toBe(1);
    expect(retryMinutes(undefined)).toBe(1);
    expect(retryMinutes('x')).toBe(1);
  });
});
