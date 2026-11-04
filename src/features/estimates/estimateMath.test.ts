import { describe, expect, it } from 'vitest';
import {
  addFull,
  defaultUnit,
  estimateUnits,
  fillAmount,
  hoursMinutes,
  parseAmount,
  setLast,
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
  it('builds 2 full + ½ with +1, +1, ½', () => {
    let f = { extraFull: 0, last: 0 };
    f = addFull(f); // first full bin
    expect(fillAmount(f)).toBe(1);
    f = addFull(f);
    expect(fillAmount(f)).toBe(2);
    f = setLast(f, 0.5); // the last one is only half full
    expect(fillAmount(f)).toBe(1.5);
    f = addFull(f);
    expect(fillAmount(f)).toBe(2.5);
  });
  it('splits a typed amount back into a fill', () => {
    expect(splitAmount(2.5)).toEqual({ extraFull: 2, last: 0.5 });
    expect(splitAmount(3)).toEqual({ extraFull: 2, last: 1 });
    expect(splitAmount(0.75)).toEqual({ extraFull: 0, last: 0.75 });
    expect(splitAmount(0)).toEqual({ extraFull: 0, last: 0 });
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
      ],
      2,
    );
    expect(s).toEqual({ loads: 6, unknown: 1, hours: 2.75 });
  });
  it('has no hours without working washers, and 0 when nothing is waiting', () => {
    expect(summarize([{ loads: 3, cycleMinutes: 26 }], 0).hours).toBeNull();
    expect(summarize([{ loads: 0, cycleMinutes: 26 }], 0).hours).toBe(0);
  });
});
