import { describe, expect, it } from 'vitest';
import { cleanName, setupErrorKey } from './setupErrors';

describe('setupErrorKey', () => {
  it('maps RLS, unique, check and trigger errors to clear messages', () => {
    expect(
      setupErrorKey({ code: '42501', message: 'new row violates row-level security policy' }),
    ).toBe('setup.errors.ownerOnly');
    expect(setupErrorKey({ code: '23505', message: 'duplicate key' })).toBe(
      'setup.errors.duplicate',
    );
    expect(setupErrorKey({ code: '23514', message: 'violates check constraint' })).toBe(
      'setup.errors.invalid',
    );
    expect(
      setupErrorKey({
        code: 'P0001',
        message: 'VALIDATION_FAILED',
        details:
          'machine: in use, so its kind and area are fixed. Deactivate it and add a new machine',
      }),
    ).toBe('setup.errors.machineInUse');
    expect(
      setupErrorKey({
        code: 'P0001',
        message: 'VALIDATION_FAILED',
        details: 'label_i18n: one 1–60 character label',
      }),
    ).toBe('setup.errors.labels');
    expect(setupErrorKey(new Error('Failed to fetch'))).toBe('errors.network');
  });
});

describe('cleanName', () => {
  it('trims, collapses spaces, drops control characters and enforces 1–60', () => {
    expect(cleanName('  Washer\t7  ')).toBe('Washer 7');
    expect(cleanName('   ')).toBeNull();
    expect(cleanName('x'.repeat(61))).toBeNull();
  });
});
