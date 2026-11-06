import { describe, expect, it } from 'vitest';
import {
  ageSeconds,
  estimateServerNow,
  formatCountdown,
  freshness,
  liveStatus,
  minutesLeftRoundedUp,
  minutesSinceEnd,
  secondsLeft,
  washerNow,
} from './washerTime';

const T0 = Date.parse('2026-11-04T20:00:00Z');

describe('estimateServerNow', () => {
  it('adds device time elapsed since the fetch to the server time', () => {
    // Device clock is 10 minutes wrong; only the elapsed 5 s matters.
    const fetchedAt = T0 + 600_000;
    expect(estimateServerNow('2026-11-04T20:00:00Z', fetchedAt, fetchedAt + 5000)).toBe(T0 + 5000);
  });
  it('falls back to the device clock without a server time', () => {
    expect(estimateServerNow(null, 0, 1234)).toBe(1234);
    expect(estimateServerNow('not a date', 0, 1234)).toBe(1234);
  });
  it('never goes backwards if the device clock jumps back', () => {
    expect(estimateServerNow('2026-11-04T20:00:00Z', 5000, 1000)).toBe(T0);
  });
});

describe('secondsLeft / minutesSinceEnd', () => {
  const end = '2026-11-04T20:26:00Z';
  it('counts down to the expected end and stops at 0', () => {
    expect(secondsLeft(end, T0)).toBe(26 * 60);
    expect(secondsLeft(end, T0 + 26 * 60_000 - 1500)).toBe(2);
    expect(secondsLeft(end, T0 + 30 * 60_000)).toBe(0);
  });
  it('is null when the formula time is unknown', () => {
    expect(secondsLeft(null, T0)).toBeNull();
    expect(minutesSinceEnd(undefined, T0)).toBeNull();
  });
  it('counts whole minutes a finished washer has waited', () => {
    expect(minutesSinceEnd(end, T0)).toBe(0);
    expect(minutesSinceEnd(end, T0 + 33 * 60_000 + 59_000)).toBe(7);
  });
});

describe('formatCountdown', () => {
  it('formats m:ss and h:mm:ss', () => {
    expect(formatCountdown(0)).toBe('0:00');
    expect(formatCountdown(425)).toBe('7:05');
    expect(formatCountdown(3723)).toBe('1:02:03');
    expect(formatCountdown(-5)).toBe('0:00');
  });
  it('rounds minutes up for short text', () => {
    expect(minutesLeftRoundedUp(301)).toBe(6);
    expect(minutesLeftRoundedUp(300)).toBe(5);
    expect(minutesLeftRoundedUp(0)).toBe(0);
  });
});

describe('liveStatus', () => {
  it('turns a running washer ready when its countdown reaches 0', () => {
    expect(liveStatus('running', 12)).toBe('running');
    expect(liveStatus('running', 0)).toBe('ready');
    expect(liveStatus('running', null)).toBe('running');
  });
  it('passes known statuses through and maps anything else to unknown', () => {
    expect(liveStatus('idle', null)).toBe('idle');
    expect(liveStatus('ready', 0)).toBe('ready');
    expect(liveStatus('weird', 5)).toBe('unknown');
    expect(liveStatus(null, 5)).toBe('unknown');
  });
});

describe('ageSeconds / freshness', () => {
  it('measures data age in whole seconds', () => {
    expect(ageSeconds(1000, 21_999)).toBe(20);
    expect(ageSeconds(5000, 1000)).toBe(0);
  });
  it('bands age by the refresh period', () => {
    expect(freshness(20)).toBe('fresh');
    expect(freshness(60)).toBe('fresh');
    expect(freshness(61)).toBe('stale');
    expect(freshness(300)).toBe('stale');
    expect(freshness(301)).toBe('old');
  });
});

describe('washerNow', () => {
  const end = '2026-11-04T20:26:00Z';
  const server = '2026-11-04T20:00:00Z';
  it('counts down a running washer from the server clock', () => {
    expect(washerNow('running', end, server, 0, 60_000)).toEqual({
      status: 'running',
      left: 25 * 60,
      readyMinutes: null,
    });
  });
  it('flips to ready at the end and counts waiting minutes', () => {
    expect(washerNow('running', end, server, 0, 30 * 60_000)).toEqual({
      status: 'ready',
      left: null,
      readyMinutes: 4,
    });
  });
  it('idle has no countdown', () => {
    expect(washerNow('idle', null, server, 0, 0)).toEqual({
      status: 'idle',
      left: null,
      readyMinutes: null,
    });
  });
});
