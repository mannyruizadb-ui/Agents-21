// Error messages for the owner Setup screens. Table writes (machines, machine_down_reasons) return
// raw PostgREST errors: RLS refusals (42501), unique violations (23505), CHECK violations (23514) and
// trigger errors ('VALIDATION_FAILED' with a detail). Pure module.
import { appErrorCode, errorMessageKey } from '../washroom/rpcError';

interface PgErrorLike {
  code?: unknown;
  message?: unknown;
  details?: unknown;
}

export function setupErrorKey(e: unknown): string {
  const err = (typeof e === 'object' && e !== null ? e : {}) as PgErrorLike;
  const code = typeof err.code === 'string' ? err.code : '';
  const details = typeof err.details === 'string' ? err.details : '';
  if (code === '42501' || appErrorCode(e) === 'NOT_AUTHORIZED') return 'setup.errors.ownerOnly';
  if (code === '23505') return 'setup.errors.duplicate';
  if (code === '23514') return 'setup.errors.invalid';
  if (appErrorCode(e) === 'VALIDATION_FAILED') {
    if (/in use, so its kind and area are fixed/.test(details)) return 'setup.errors.machineInUse';
    if (/label_i18n/.test(details)) return 'setup.errors.labels';
    return 'setup.errors.invalid';
  }
  return errorMessageKey(e);
}

/** Clean names: 1–60 characters, no control characters (the DB CHECK); returns the trimmed name or null. */
export function cleanName(input: string, max = 60): string | null {
  const s = input
    // eslint-disable-next-line no-control-regex -- the DB refuses control characters
    .replace(/[\u0000-\u001f\u007f]+/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
  return s.length >= 1 && s.length <= max ? s : null;
}
