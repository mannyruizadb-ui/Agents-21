import { describe, expect, it } from 'vitest';
import { pinErrorKey, pinProblem } from './pinRules';

describe('pinProblem', () => {
  it('accepts a 4-digit PIN typed twice', () => {
    expect(pinProblem('4821', '4821')).toBeNull();
  });
  it('refuses anything but 4 digits', () => {
    expect(pinProblem('482', '482')).toBe('digits');
    expect(pinProblem('48a1', '48a1')).toBe('digits');
  });
  it('refuses the PINs the server refuses', () => {
    expect(pinProblem('1234', '1234')).toBe('easy');
    expect(pinProblem('7777', '7777')).toBe('easy');
  });
  it('catches a typo in the second box', () => {
    expect(pinProblem('4821', '4812')).toBe('mismatch');
  });
});

describe('pinErrorKey', () => {
  it('maps the server details', () => {
    const err = (details: string) => ({ code: 'P0001', message: 'VALIDATION_FAILED', details });
    expect(pinErrorKey(err('pin: already used by another active person in this plant'))).toBe(
      'setup.pins.errors.inUse',
    );
    expect(pinErrorKey(err('pin: too easy to guess (0000, 1234 or one repeated digit)'))).toBe(
      'setup.pins.errors.easy',
    );
  });
});
