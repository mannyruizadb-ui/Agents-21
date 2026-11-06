// Entry PIN rules for the Setup → PINs screen. They mirror set_staff_pin (the server is the final
// check): exactly 4 digits, not 0000…9999 (one repeated digit) and not 1234. Pure module.
import { appErrorCode, errorMessageKey } from '../washroom/rpcError';

export type PinProblem = 'digits' | 'easy' | 'mismatch';

export function pinProblem(pin: string, again: string): PinProblem | null {
  if (!/^[0-9]{4}$/.test(pin)) return 'digits';
  if (pin === '1234' || /^(.)\1{3}$/.test(pin)) return 'easy';
  if (pin !== again) return 'mismatch';
  return null;
}

interface PgErrorLike {
  details?: unknown;
  detail?: unknown;
}

/** set_staff_pin errors → a translation key. */
export function pinErrorKey(e: unknown): string {
  const err = (typeof e === 'object' && e !== null ? e : {}) as PgErrorLike;
  const details = [err.details, err.detail].filter((d) => typeof d === 'string').join(' ');
  if (appErrorCode(e) === 'NOT_AUTHORIZED') return 'setup.errors.ownerOnly';
  if (appErrorCode(e) === 'VALIDATION_FAILED') {
    if (/already used/.test(details)) return 'setup.pins.errors.inUse';
    if (/too easy/.test(details)) return 'setup.pins.errors.easy';
    return 'setup.pins.errors.digits';
  }
  return errorMessageKey(e);
}
