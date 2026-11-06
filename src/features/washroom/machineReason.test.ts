import { describe, expect, it } from 'vitest';
import { buildDownReason, reasonText } from './machineReason';

describe('buildDownReason', () => {
  it('keeps the code and optional details', () => {
    expect(buildDownReason('water_pump', '')).toEqual({
      ok: true,
      code: 'water_pump',
      details: null,
    });
    expect(buildDownReason('leaking', '  door  seal ')).toEqual({
      ok: true,
      code: 'leaking',
      details: 'door seal',
    });
  });
  it('needs a pick, and details for other', () => {
    expect(buildDownReason(null, 'x')).toEqual({ ok: false, error: 'pick' });
    expect(buildDownReason('other', '   ')).toEqual({ ok: false, error: 'details' });
    expect(buildDownReason('other', 'Belt broke')).toEqual({
      ok: true,
      code: 'other',
      details: 'Belt broke',
    });
  });
  it('removes control characters and enforces 200 characters of details', () => {
    expect(buildDownReason('other', 'a\nb\tc')).toMatchObject({ details: 'a b c' });
    expect(buildDownReason('wont_start', 'x'.repeat(200))).toMatchObject({ ok: true });
    expect(buildDownReason('wont_start', 'x'.repeat(201))).toEqual({ ok: false, error: 'tooLong' });
  });
});

describe('reasonText', () => {
  const es = (c: string) => ({ water_pump: 'Bomba de agua', other: 'Otro' })[c] ?? c;
  it("renders the code in the viewer's language plus details", () => {
    expect(reasonText('water_pump', null, es)).toBe('Bomba de agua');
    expect(reasonText('water_pump', 'grinding noise', es)).toBe('Bomba de agua: grinding noise');
    expect(reasonText('other', 'Belt broke', es)).toBe('Belt broke');
    expect(reasonText('other', null, es)).toBe('Otro');
  });
  it('falls back to the old free text, and to nothing', () => {
    expect(reasonText(null, 'Water pump: old row', es)).toBe('Water pump: old row');
    expect(reasonText('bogus', 'x', es)).toBe('x');
    expect(reasonText(null, null, es)).toBeNull();
  });
});
