import { describe, expect, it } from 'vitest';
import { memoryStore } from '../../lib/scopedStore';
import { isUnavailable, readSeen, SEEN_KEY, seenAfterViewing } from './alertsData';

describe('isUnavailable', () => {
  it('treats a missing function or NOT_AUTHORIZED as unavailable', () => {
    expect(isUnavailable({ code: 'PGRST202', message: 'Could not find the function' })).toBe(true);
    expect(isUnavailable({ message: 'Could not find the function public.get_my_alerts' })).toBe(
      true,
    );
    expect(isUnavailable({ code: 'P0001', message: 'NOT_AUTHORIZED' })).toBe(true);
  });
  it('keeps other failures as errors', () => {
    expect(isUnavailable({ code: 'P0001', message: 'VALIDATION_FAILED' })).toBe(false);
    expect(isUnavailable(new TypeError('Failed to fetch'))).toBe(false);
  });
});

describe('alerts seen marker', () => {
  const row = (at: string) => ({
    alert_id: at,
    kind: 'machine_down',
    created_at: at,
    payload: {},
    still_current: true,
  });
  it('remembers the newest alert time, else now, and never moves back', () => {
    const now = Date.parse('2026-11-06T12:00:00Z');
    expect(
      seenAfterViewing([row('2026-11-06T10:00:00Z'), row('2026-11-06T11:00:00Z')], null, now),
    ).toBe('2026-11-06T11:00:00Z');
    expect(seenAfterViewing([], null, now)).toBe('2026-11-06T12:00:00.000Z');
    expect(seenAfterViewing([row('2026-11-06T09:00:00Z')], '2026-11-06T10:00:00Z', now)).toBe(
      '2026-11-06T10:00:00Z',
    );
  });
  it('ignores an unreadable stored value', () => {
    const s = memoryStore();
    expect(readSeen(s)).toBeNull();
    s.setItem(SEEN_KEY, 'garbage');
    expect(readSeen(s)).toBeNull();
    s.setItem(SEEN_KEY, '2026-11-06T10:00:00Z');
    expect(readSeen(s)).toBe('2026-11-06T10:00:00Z');
  });
});
