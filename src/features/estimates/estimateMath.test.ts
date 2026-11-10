import { describe, expect, it } from 'vitest';
import {
  defaultUnit,
  estimateUnits,
  fillAmount,
  hoursMinutes,
  parseAmount,
  rowWashHours,
  setPart,
  stepFull,
  splitAmount,
  summarize,
  toLoads,
  washHours,
} from './estimateMath';

const linen = {
  allow_basket_estimates: false,
  allow_bin_estimates: true,
  loads_per_basket: null,
  loads_per_bin: 2,
};
const towels = {
  allow_basket_estimates: true,
  allow_bin_estimates: true,
  loads_per_basket: 2,
  loads_per_bin: 2.5,
};
const mops = {
  allow_basket_estimates: false,
  allow_bin_estimates: false,
  loads_per_basket: null,
  loads_per_bin: null,
};

describe('units', () => {
  it('offers only allowed containers, loads always', () => {
    expect(estimateUnits(linen)).toEqual(['bin', 'load']);
    expect(estimateUnits(towels)).toEqual(['bin', 'basket', 'load']);
    expect(estimateUnits(mops)).toEqual(['load']);
  });
  it('starts on the last unit when still allowed', () => {
    expect(defaultUnit(towels, 'basket')).toBe('basket');
    expect(defaultUnit(linen, 'basket')).toBe('bin');
    // Mats: both containers allowed, the group prefers the basket (as the drivers offload them).
    const mats = {
      ...linen,
      allow_basket_estimates: true,
      loads_per_basket: 3.5,
      default_estimate_unit: 'basket',
    };
    expect(defaultUnit(mats, null)).toBe('basket');
    expect(defaultUnit(mats, 'bin')).toBe('bin');
    expect(defaultUnit(mops, null)).toBe('load');
  });
});

describe('conversion', () => {
  it('converts with the group factor and never guesses', () => {
    expect(toLoads(2.5, 'bin', linen)).toBe(5);
    expect(toLoads(0.5, 'basket', towels)).toBe(1);
    expect(toLoads(3, 'load', mops)).toBe(3);
    expect(toLoads(1, 'basket', linen)).toBeNull();
  });
  it('washing hours need loads and a formula time', () => {
    expect(washHours(5, 59)).toBeCloseTo(4.9167, 3);
    expect(washHours(null, 59)).toBeNull();
    expect(washHours(2, null)).toBeNull();
    expect(hoursMinutes(4.9167)).toEqual({ h: 4, m: 55 });
    expect(hoursMinutes(0.04)).toEqual({ h: 0, m: 0 });
  });
});

describe('bin fill', () => {
  it('2 full + ½ with the stepper and a partial', () => {
    let f = { full: 0, part: 0 };
    f = stepFull(stepFull(f, 1), 1);
    expect(fillAmount(f)).toBe(2);
    f = setPart(f, 0.5);
    expect(fillAmount(f)).toBe(2.5);
    expect(fillAmount(setPart(f, 0))).toBe(2);
  });
  it('the stepper never goes below 0', () => {
    expect(stepFull({ full: 0, part: 0.25 }, -1)).toEqual({ full: 0, part: 0.25 });
    expect(stepFull({ full: 3, part: 0 }, -1)).toEqual({ full: 2, part: 0 });
  });
  it('splits a typed amount back into a fill', () => {
    expect(splitAmount(2.5)).toEqual({ full: 2, part: 0.5 });
    expect(splitAmount(3)).toEqual({ full: 3, part: 0 });
    expect(splitAmount(0.75)).toEqual({ full: 0, part: 0.75 });
    expect(splitAmount(2.3)).toEqual({ full: 2, part: 0.3 });
    expect(splitAmount(0)).toEqual({ full: 0, part: 0 });
  });
  it('parses amounts like the server (0–10,000, 2 decimals)', () => {
    expect(parseAmount('2,5')).toBe(2.5);
    expect(parseAmount('0')).toBe(0);
    expect(parseAmount('10000')).toBe(10000);
    for (const bad of ['', '-1', '1.234', '10000.5', 'x']) expect(parseAmount(bad)).toBeNull();
  });
});

describe('summarize', () => {
  it('totals known loads, counts unknown ones, and spreads hours over washer capacity', () => {
    const s = summarize(
      [
        { loads: 5, cycleMinutes: 60 },
        { loads: 1, cycleMinutes: 30 },
        { loads: null, cycleMinutes: 30 },
        { loads: 0, cycleMinutes: 26 },
        { loads: 2, cycleMinutes: null },
      ],
      2,
    );
    expect(s).toEqual({ loads: 8, unknown: 1, hours: 2.75, noTime: 1 });
  });
  it('has no hours without working washers, and 0 when nothing is waiting', () => {
    expect(summarize([{ loads: 3, cycleMinutes: 26 }], 0).hours).toBeNull();
    expect(summarize([{ loads: 0, cycleMinutes: 26 }], 0).hours).toBe(0);
  });
});

describe('rowWashHours (audit 2026-11-10)', () => {
  it('uses the whole loads the row shows, not the fraction', () => {
    // 2.3 loads is shown as 3 loads: 3 × 40 min = 2 h, not 2.3 × 40 min.
    expect(rowWashHours(2.3, 40)).toBe(2);
    expect(rowWashHours(2, 30)).toBe(1);
    expect(rowWashHours(0, 30)).toBe(0);
  });
  it('is null when the loads or the cycle time are unknown', () => {
    expect(rowWashHours(null, 30)).toBeNull();
    expect(rowWashHours(2, null)).toBeNull();
  });
});
