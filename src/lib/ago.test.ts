import { describe, expect, it } from 'vitest';
import { agoParts } from './ago';

const NOW = Date.parse('2026-11-09T15:00:00Z');
const MIN = 60_000;

describe('agoParts', () => {
  it('minutes under an hour', () => {
    expect(agoParts(NOW - 12 * MIN, NOW)).toEqual({ unit: 'min', count: 12 });
    expect(agoParts(NOW - 59 * MIN - 59_000, NOW)).toEqual({ unit: 'min', count: 59 });
  });
  it('a time in the future (clock skew) reads 0 min', () => {
    expect(agoParts(NOW + 5 * MIN, NOW)).toEqual({ unit: 'min', count: 0 });
  });
  it('whole hours from 1 h to 47 h', () => {
    expect(agoParts(NOW - 60 * MIN, NOW)).toEqual({ unit: 'hour', count: 1 });
    expect(agoParts(NOW - 125 * MIN, NOW)).toEqual({ unit: 'hour', count: 2 });
    expect(agoParts(NOW - 47 * 60 * MIN, NOW)).toEqual({ unit: 'hour', count: 47 });
  });
  it('days from 48 h', () => {
    expect(agoParts(NOW - 48 * 60 * MIN, NOW)).toEqual({ unit: 'day', count: 2 });
    expect(agoParts(NOW - 80 * 60 * MIN, NOW)).toEqual({ unit: 'day', count: 3 });
  });
});
