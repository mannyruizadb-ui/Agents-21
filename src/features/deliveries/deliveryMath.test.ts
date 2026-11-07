import { describe, expect, it } from 'vitest';
import {
  binsToLoads,
  clampBins,
  deliveryLines,
  enteredAtParam,
  parseBins,
  parseHistoryLines,
  stepBins,
} from './deliveryMath';

describe('bins in quarters', () => {
  it('steps by a quarter and stays within 0–50', () => {
    expect(stepBins(0, 1)).toBe(0.25);
    expect(stepBins(0.25, -1)).toBe(0);
    expect(stepBins(0, -1)).toBe(0);
    expect(stepBins(50, 1)).toBe(50);
    expect(stepBins(1.75, 1)).toBe(2);
  });
  it('clamps and rounds to quarters', () => {
    expect(clampBins(1.3)).toBe(1.25);
    expect(clampBins(-2)).toBe(0);
    expect(clampBins(80)).toBe(50);
    expect(clampBins(Number.NaN)).toBe(0);
  });
  it('parses typed amounts (EN and ES decimals, fractions)', () => {
    expect(parseBins('')).toBe(0);
    expect(parseBins('2')).toBe(2);
    expect(parseBins('1.5')).toBe(1.5);
    expect(parseBins('1,75')).toBe(1.75);
    expect(parseBins('.25')).toBe(0.25);
    expect(parseBins('½')).toBe(0.5);
    expect(parseBins('2¾')).toBe(2.75);
    expect(parseBins('1 1/2')).toBe(1.5);
    expect(parseBins('3/4')).toBe(0.75);
  });
  it('refuses what the server would refuse', () => {
    expect(parseBins('1.3')).toBeNull();
    expect(parseBins('51')).toBeNull();
    expect(parseBins('-1')).toBeNull();
    expect(parseBins('abc')).toBeNull();
    expect(parseBins('1/0')).toBeNull();
  });
});

describe('loads and lines', () => {
  it('converts only with a factor (no guessing)', () => {
    expect(binsToLoads(2.5, 4)).toBe(10);
    expect(binsToLoads(2, null)).toBeNull();
    expect(binsToLoads(2, 0)).toBeNull();
  });
  it('keeps group order and drops empty groups', () => {
    expect(deliveryLines(['a', 'b', 'c'], { c: 1, a: 0.5, b: 0 })).toEqual([
      { washGroupId: 'a', bins: 0.5 },
      { washGroupId: 'c', bins: 1 },
    ]);
  });
});

describe('enteredAtParam', () => {
  const now = Date.parse('2026-11-07T10:00:00Z');
  it('lets the server stamp a fresh entry', () => {
    expect(enteredAtParam('2026-11-07T09:59:30Z', now)).toBeUndefined();
    expect(enteredAtParam('2026-11-07T10:00:30Z', now)).toBeUndefined();
  });
  it('keeps the real time of an entry that waited offline', () => {
    expect(enteredAtParam('2026-11-07T09:30:00Z', now)).toBe('2026-11-07T09:30:00Z');
  });
  it('ignores missing or bad times', () => {
    expect(enteredAtParam(undefined, now)).toBeUndefined();
    expect(enteredAtParam('x', now)).toBeUndefined();
  });
});

describe('parseHistoryLines', () => {
  it('reads the RPC lines and skips junk', () => {
    expect(
      parseHistoryLines([
        {
          wash_group_id: 'g',
          wash_group_name: 'Napkins',
          wash_group_name_i18n: { es: 'Servilletas' },
          bins: 2,
          loads: null,
          queue_status: 'queued',
        },
        { wash_group_id: 'h', bins: '1.5', loads: '6' },
        { bins: 1 },
        'x',
      ]),
    ).toEqual([
      {
        washGroupId: 'g',
        name: 'Napkins',
        nameI18n: { es: 'Servilletas' },
        bins: 2,
        loads: null,
        queueStatus: 'queued',
      },
      { washGroupId: 'h', name: '', nameI18n: null, bins: 1.5, loads: 6, queueStatus: null },
    ]);
    expect(parseHistoryLines(null)).toEqual([]);
  });
});
