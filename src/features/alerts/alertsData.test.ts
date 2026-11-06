import { describe, expect, it } from 'vitest';
import { isUnavailable } from './alertsData';

describe('isUnavailable', () => {
  it('treats a missing function or NOT_AUTHORIZED as unavailable', () => {
    expect(isUnavailable({ code: 'PGRST202', message: 'Could not find the function' })).toBe(true);
    expect(isUnavailable({ message: 'Could not find the function public.get_my_alerts' })).toBe(
      true,
    );
    expect(isUnavailable({ code: 'P0001', message: 'NOT_AUTHORIZED' })).toBe(true);
  });
  it('keeps other failures as errors', () => {
    expect(isUnavailable({ code: 'P0001', message: 'VALIDATION_FAILED' })).toBe(false);
    expect(isUnavailable(new TypeError('Failed to fetch'))).toBe(false);
  });
});
