import { describe, expect, it } from 'vitest';
import { buildDownReason } from './machineReason';

describe('buildDownReason', () => {
  it('uses the pick label, with details after a colon', () => {
    expect(buildDownReason('waterPump', 'Water pump', '')).toEqual({
      ok: true,
      reason: 'Water pump',
    });
    expect(buildDownReason('leaking', 'Leaking', '  door  seal ')).toEqual({
      ok: true,
      reason: 'Leaking: door seal',
    });
  });
  it('needs a pick, and details for Other', () => {
    expect(buildDownReason(null, '', 'x')).toEqual({ ok: false, error: 'pick' });
    expect(buildDownReason('other', 'Other', '   ')).toEqual({ ok: false, error: 'details' });
    expect(buildDownReason('other', 'Other', 'Belt broke')).toEqual({
      ok: true,
      reason: 'Belt broke',
    });
  });
  it('removes control characters and enforces 200 characters', () => {
    expect(buildDownReason('other', 'Other', 'a\nb\tc')).toEqual({ ok: true, reason: 'a b c' });
    expect(buildDownReason('other', 'Other', 'x'.repeat(200))).toMatchObject({ ok: true });
    expect(buildDownReason('other', 'Other', 'x'.repeat(201))).toEqual({
      ok: false,
      error: 'tooLong',
    });
    expect(buildDownReason('wontStart', "Won't start", 'x'.repeat(190))).toEqual({
      ok: false,
      error: 'tooLong',
    });
  });
});
