import { describe, expect, it } from 'vitest';
import { pageAge, pageAgeWarns } from './liveDataAge';

describe('page data age', () => {
  const now = 1_000_000;
  it('is null until something has loaded', () => {
    expect(pageAge([], now)).toBeNull();
    expect(
      pageAge([{ updatedAt: 0, intervalMs: 30_000, isError: false, isFetching: true }], now),
    ).toBeNull();
  });

  it('picks the read most overdue for its own period', () => {
    const a = pageAge(
      [
        { updatedAt: now - 50_000, intervalMs: 60_000, isError: false, isFetching: false },
        { updatedAt: now - 40_000, intervalMs: 30_000, isError: false, isFetching: true },
      ],
      now,
    );
    expect(a).toEqual({
      updatedAt: now - 40_000,
      refreshSeconds: 30,
      isError: false,
      isFetching: true,
    });
    expect(pageAgeWarns(a, now)).toBe(false);
  });

  it('warns when a read is past two periods or any read failed', () => {
    const old = pageAge(
      [{ updatedAt: now - 130_000, intervalMs: 60_000, isError: false, isFetching: false }],
      now,
    );
    expect(pageAgeWarns(old, now)).toBe(true);
    const failed = pageAge(
      [{ updatedAt: now - 1_000, intervalMs: 60_000, isError: true, isFetching: false }],
      now,
    );
    expect(pageAgeWarns(failed, now)).toBe(true);
  });
});
