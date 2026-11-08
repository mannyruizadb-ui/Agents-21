import { describe, expect, it, vi } from 'vitest';
import { changePasswordProblem } from './changePasswordErrors';
import { ManageUsersError } from '../../features/admin/manageUsers';

vi.mock('../../lib/supabase', () => ({ supabase: {} }));

describe('changePasswordProblem', () => {
  it('maps manage-users errors to screen messages', () => {
    const e = (code: string, reason?: string, s?: number) => new ManageUsersError(code, reason, s);
    expect(changePasswordProblem(e('LOCKED', undefined, 600))).toEqual({
      kind: 'locked',
      minutes: 10,
    });
    expect(changePasswordProblem(e('RATE_LIMITED'))).toEqual({ kind: 'rateLimited' });
    expect(changePasswordProblem(e('VALIDATION_FAILED', 'wrong_current_password'))).toEqual({
      kind: 'wrongCurrent',
    });
    expect(changePasswordProblem(e('VALIDATION_FAILED', 'same_password'))).toEqual({
      kind: 'same',
    });
    expect(changePasswordProblem(e('VALIDATION_FAILED', 'password_too_simple'))).toEqual({
      kind: 'rule',
      key: 'tooSimple',
    });
    expect(changePasswordProblem(e('VALIDATION_FAILED', 'password_too_short'))).toEqual({
      kind: 'rule',
      key: 'tooShort',
    });
    expect(changePasswordProblem(e('VALIDATION_FAILED', 'password_too_long'))).toEqual({
      kind: 'rule',
      key: 'tooLong',
    });
    expect(changePasswordProblem(e('INTERNAL'))).toEqual({ kind: 'failed' });
    expect(changePasswordProblem(new Error('x'))).toEqual({ kind: 'failed' });
  });
});
