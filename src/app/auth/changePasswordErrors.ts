import { ManageUsersError } from '../../features/admin/manageUsers';
import { isPasswordProblem, passwordProblemKey } from '../../lib/passwordRules';
import { retryMinutes } from './signInApi';

// What a manage-users change_own_password error means for the change-password screen (pure).

export type Problem =
  | { kind: 'rule'; key: 'tooShort' | 'tooLong' | 'tooSimple' }
  | { kind: 'currentRequired' }
  | { kind: 'wrongCurrent' }
  | { kind: 'mismatch' }
  | { kind: 'same' }
  | { kind: 'locked'; minutes: number }
  | { kind: 'rateLimited' }
  | { kind: 'failed' };

/** What a manage-users change_own_password error means for this screen. */
export function changePasswordProblem(e: unknown): Problem {
  if (!(e instanceof ManageUsersError)) return { kind: 'failed' };
  if (e.code === 'LOCKED') return { kind: 'locked', minutes: retryMinutes(e.retryAfterSeconds) };
  if (e.code === 'RATE_LIMITED') return { kind: 'rateLimited' };
  if (e.reason === 'wrong_current_password') return { kind: 'wrongCurrent' };
  if (e.reason === 'same_password') return { kind: 'same' };
  if (isPasswordProblem(e.reason)) return { kind: 'rule', key: passwordProblemKey(e.reason) };
  return { kind: 'failed' };
}
