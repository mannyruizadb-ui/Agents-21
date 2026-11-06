import { describe, expect, it } from 'vitest';
import {
  buildDownReason,
  codeFromLabel,
  reasonLabel,
  reasonText,
  reorderUpdates,
} from './machineReason';

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
  it('needs a pick, and details when the reason requires them', () => {
    expect(buildDownReason(null, 'x')).toEqual({ ok: false, error: 'pick' });
    expect(buildDownReason('other', '   ')).toEqual({ ok: false, error: 'details' });
    expect(buildDownReason('belt', '', true)).toEqual({ ok: false, error: 'details' });
    expect(buildDownReason('belt', '', false)).toMatchObject({ ok: true });
  });
  it('removes control characters and enforces 200 characters of details', () => {
    expect(buildDownReason('other', 'a\nb\tc')).toMatchObject({ details: 'a b c' });
    expect(buildDownReason('wont_start', 'x'.repeat(201))).toEqual({ ok: false, error: 'tooLong' });
  });
});

describe('reasonLabel', () => {
  const fallback = (c: string) => ({ water_pump: 'Bomba de agua (locale)' })[c] ?? null;
  it("uses the plant's label in the viewer's language, then English", () => {
    expect(reasonLabel('belt', { en: 'Belt', es: 'Correa' }, 'es', fallback)).toBe('Correa');
    expect(reasonLabel('belt', { en: 'Belt' }, 'es', fallback)).toBe('Belt');
  });
  it('falls back to the locale strings, then the code', () => {
    expect(reasonLabel('water_pump', null, 'es', fallback)).toBe('Bomba de agua (locale)');
    expect(reasonLabel('mystery', {}, 'es', fallback)).toBe('mystery');
  });
});

describe('reasonText', () => {
  const label = (c: string) => ({ water_pump: 'Bomba de agua', other: 'Otro' })[c] ?? c;
  it('renders the label plus details; other shows details alone', () => {
    expect(reasonText('water_pump', 'grinding', label)).toBe('Bomba de agua: grinding');
    expect(reasonText('other', 'Belt broke', label)).toBe('Belt broke');
    expect(reasonText('other', null, label)).toBe('Otro');
    expect(reasonText(null, 'old text', label)).toBe('old text');
    expect(reasonText(null, null, label)).toBeNull();
  });
});

describe('codeFromLabel', () => {
  it('makes a DB-valid, unique code from the English label', () => {
    expect(codeFromLabel('Belt broken!', [])).toBe('belt_broken');
    expect(codeFromLabel('Válvula de vapor', [])).toBe('valvula_de_vapor');
    expect(codeFromLabel('24V sensor', [])).toBe('r_24v_sensor');
    expect(codeFromLabel('Leaking', ['leaking', 'leaking_2'])).toBe('leaking_3');
    expect(codeFromLabel('!', [])).toBe('reason');
    for (const c of ['belt_broken', 'r_24v_sensor', 'leaking_3'])
      expect(c).toMatch(/^[a-z][a-z0-9_]{1,39}$/);
  });
});

describe('reorderUpdates', () => {
  const rows = [
    { id: 'a', sort_order: 10 },
    { id: 'b', sort_order: 20 },
    { id: 'c', sort_order: 90 },
  ];
  it('swaps neighbors and renumbers only what changes', () => {
    expect(reorderUpdates(rows, 'c', 'up')).toEqual([
      { id: 'c', sort_order: 20 },
      { id: 'b', sort_order: 30 },
    ]);
    expect(reorderUpdates(rows, 'a', 'down')).toEqual([
      { id: 'b', sort_order: 10 },
      { id: 'a', sort_order: 20 },
      { id: 'c', sort_order: 30 },
    ]);
  });
  it('does nothing past the ends', () => {
    expect(reorderUpdates(rows, 'a', 'up')).toEqual([]);
    expect(reorderUpdates(rows, 'c', 'down')).toEqual([]);
  });
});
