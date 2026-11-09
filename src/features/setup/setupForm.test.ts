import { describe, expect, it } from 'vitest';
import {
  binFactorMissing,
  cleanFormulaNo,
  factorProblems,
  fromNameI18n,
  nextSortOrder,
  otherLanguages,
  parseLoadFactor,
  parseLoadsPer,
  parseMinutes,
  toNameI18n,
} from './setupForm';

describe('number fields', () => {
  it('loads per basket/bin: blank, (0, 20], 3 decimals, comma accepted', () => {
    expect(parseLoadsPer('')).toBeNull();
    expect(parseLoadsPer(' 3.5 ')).toBe(3.5);
    expect(parseLoadsPer('3,5')).toBe(3.5);
    expect(parseLoadsPer('.25')).toBe(0.25);
    expect(parseLoadsPer('20')).toBe(20);
    expect(parseLoadsPer('0')).toBe('invalid');
    expect(parseLoadsPer('35')).toBe('invalid');
    expect(parseLoadsPer('1.2345')).toBe('invalid');
    expect(parseLoadsPer('-1')).toBe('invalid');
    expect(parseLoadsPer('abc')).toBe('invalid');
  });
  it('load factor: 0.25–4.00, required', () => {
    expect(parseLoadFactor('1.19')).toBe(1.19);
    expect(parseLoadFactor('0.25')).toBe(0.25);
    expect(parseLoadFactor('4')).toBe(4);
    expect(parseLoadFactor('')).toBe('invalid');
    expect(parseLoadFactor('0.2')).toBe('invalid');
    expect(parseLoadFactor('4.01')).toBe('invalid');
    expect(parseLoadFactor('1.199')).toBe('invalid');
  });
  it('cycle minutes: blank or 1–300 whole', () => {
    expect(parseMinutes('')).toBeNull();
    expect(parseMinutes('59')).toBe(59);
    expect(parseMinutes('300')).toBe(300);
    expect(parseMinutes('0')).toBe('invalid');
    expect(parseMinutes('301')).toBe('invalid');
    expect(parseMinutes('5.5')).toBe('invalid');
  });
  it('formula number: 1–20 clean characters', () => {
    expect(cleanFormulaNo(' 4 ')).toBe('4');
    expect(cleanFormulaNo('')).toBeNull();
    expect(cleanFormulaNo('x'.repeat(21))).toBeNull();
  });
});

describe('names per language', () => {
  it('keeps filled languages, drops blanks, refuses too long', () => {
    expect(toNameI18n({ es: ' Alfombras  negras ', ht: '' }, ['es', 'ht'])).toEqual({
      es: 'Alfombras negras',
    });
    expect(toNameI18n({ es: 'x'.repeat(61) }, ['es'])).toBeNull();
    expect(fromNameI18n({ es: 'Alfombras', fr: 1 }, ['es', 'ht'])).toEqual({
      es: 'Alfombras',
      ht: '',
    });
    expect(fromNameI18n(null, ['es'])).toEqual({ es: '' });
  });
  it('edits the enabled languages the app has, minus the default', () => {
    expect(otherLanguages(['en', 'es'], 'en', ['en', 'es'])).toEqual(['es']);
    expect(otherLanguages(['en', 'es', 'ht'], 'en', ['en', 'es'])).toEqual(['es']);
    expect(otherLanguages(undefined, 'en', ['en', 'es'])).toEqual(['es']);
  });
});

describe('factors', () => {
  const base = {
    loads_per_basket: null,
    loads_per_bin: null,
    allow_basket_estimates: false,
    allow_bin_estimates: false,
    default_estimate_unit: 'load' as const,
  };
  it('mirrors the DB checks', () => {
    expect(factorProblems(base)).toEqual([]);
    expect(factorProblems({ ...base, allow_bin_estimates: true })).toEqual([
      'setup.groups.errors.binNeedsFactor',
    ]);
    expect(factorProblems({ ...base, default_estimate_unit: 'basket' })).toEqual([
      'setup.groups.errors.defaultBasket',
    ]);
    expect(
      factorProblems({
        ...base,
        loads_per_basket: 3.5,
        allow_basket_estimates: true,
        default_estimate_unit: 'basket',
      }),
    ).toEqual([]);
  });
  it('flags a blank loads per bin on active customer groups only', () => {
    const g = { customer_id: 'c1', active: true, loads_per_bin: null, allow_bin_estimates: false };
    expect(binFactorMissing(g)).toBe(true);
    expect(binFactorMissing({ ...g, loads_per_bin: 2 })).toBe(false);
    expect(binFactorMissing({ ...g, active: false })).toBe(false);
    expect(binFactorMissing({ ...g, customer_id: null })).toBe(false);
  });
  it('next sort order', () => {
    expect(nextSortOrder([])).toBe(10);
    expect(nextSortOrder([10, 40, 30])).toBe(50);
  });
});
