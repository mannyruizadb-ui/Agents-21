import { describe, expect, it } from 'vitest';
import {
  fractionText,
  isApproximateUnit,
  pluralCount,
  previewLoads,
  rewashUnits,
} from './qtyFormat';

const fmt = (n: number) => String(n);

describe('qtyFormat', () => {
  it('shows quarter fractions as symbols', () => {
    expect(fractionText(0.5, fmt)).toBe('½');
    expect(fractionText(0.25, fmt)).toBe('¼');
    expect(fractionText(1.75, fmt)).toBe('1¾');
    expect(fractionText(2, fmt)).toBe('2');
    expect(fractionText(1.3, fmt)).toBe('1.3');
  });
  it('treats every unit but load as approximate', () => {
    expect(isApproximateUnit('load')).toBe(false);
    expect(isApproximateUnit('bin')).toBe(true);
    expect(isApproximateUnit('basket')).toBe(true);
    expect(isApproximateUnit('piece')).toBe(true);
  });
  it('reads amounts up to 1 as singular', () => {
    expect(pluralCount(0.5)).toBe(1);
    expect(pluralCount(1)).toBe(1);
    expect(pluralCount(2.5)).toBe(2.5);
  });
  it('previews loads from the group factor, null without one', () => {
    expect(previewLoads(0.5, 'bin', null, 4)).toBe(2);
    expect(previewLoads(0.75, 'basket', 0.333, null)).toBe(0.25);
    expect(previewLoads(1, 'bin', 1, null)).toBeNull();
    expect(previewLoads(3, 'load', null, null)).toBe(3);
    expect(previewLoads(3, 'piece', 1, 1)).toBeNull();
  });
});

describe('rewashUnits', () => {
  it('offers only the containers a group allows', () => {
    expect(rewashUnits({ allow_basket_estimates: false, allow_bin_estimates: false })).toEqual([
      'load',
    ]);
    expect(rewashUnits({ allow_basket_estimates: true, allow_bin_estimates: true })).toEqual([
      'load',
      'basket',
      'bin',
    ]);
    expect(rewashUnits({ allow_basket_estimates: false, allow_bin_estimates: true })).toEqual([
      'load',
      'bin',
    ]);
  });
});
