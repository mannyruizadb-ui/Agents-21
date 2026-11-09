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

  it('maps the wash group and formula refusals (Setup → Wash groups / Formulas)', () => {
    const vf = (details: string) => ({ code: 'P0001', message: 'VALIDATION_FAILED', details });
    expect(
      setupErrorKey(
        vf('wash_formula: active wash groups still use it; give them another formula first'),
      ),
    ).toBe('setup.errors.formulaInUse');
    expect(setupErrorKey(vf('wash_formula_id: that formula is retired (inactive)'))).toBe(
      'setup.errors.formulaRetired',
    );
    expect(setupErrorKey(vf('name_i18n: 1–60 clean characters'))).toBe('setup.errors.names');
    const check = (constraint: string) => ({
      code: '23514',
      message: `new row for relation violates check constraint "${constraint}"`,
    });
    expect(setupErrorKey(check('wash_groups_loads_per_bin_range'))).toBe('setup.errors.loadsPer');
    expect(setupErrorKey(check('machines_load_factor_range'))).toBe('setup.errors.loadFactor');
    expect(setupErrorKey(check('wash_formulas_cycle_minutes_check'))).toBe('setup.errors.minutes');
    expect(setupErrorKey(check('something_else'))).toBe('setup.errors.invalid');
    expect(
      setupErrorKey({
        code: 'P0001',
        message: 'NOT_AUTHORIZED',
        details: 'load factors: owner, or a manager the owner granted can_edit_load_factors',
      }),
    ).toBe('setup.errors.ownerOnly');
  });
});

describe('cleanName', () => {
  it('trims, collapses spaces, drops control characters and enforces 1–60', () => {
    expect(cleanName('  Washer\t7  ')).toBe('Washer 7');
    expect(cleanName('   ')).toBeNull();
    expect(cleanName('x'.repeat(61))).toBeNull();
  });
});
