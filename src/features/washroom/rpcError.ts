// Errors from the PlantBoard RPCs. Postgres `raise exception 'CODE' using detail = '...'` reaches the
// client as a PostgREST error whose message is the PRD §5.1 code. Anything else (no network, 5xx,
// an expired token) is treated as temporary.

export const APP_ERROR_CODES = [
  'NOT_AUTHORIZED',
  'VALIDATION_FAILED',
  'QUEUE_VERSION_CONFLICT',
  'COUNT_MODE_MISMATCH',
  'INVALID_STATUS_TRANSITION',
  'OUT_OF_RANGE_TIMESTAMP',
  'RATE_LIMITED',
] as const;

export type AppErrorCode = (typeof APP_ERROR_CODES)[number];

export class RpcError extends Error {
  constructor(
    /** A PRD §5.1 code, or null for a network / unknown failure. */
    readonly code: AppErrorCode | null,
    readonly detail: string | null,
    message: string,
  ) {
    super(message);
    this.name = 'RpcError';
  }
}

interface ErrorLike {
  message?: unknown;
  details?: unknown;
  detail?: unknown;
}

function asErrorLike(e: unknown): ErrorLike | null {
  return typeof e === 'object' && e !== null ? (e as ErrorLike) : null;
}

/** The PRD §5.1 code in an error, or null. */
export function appErrorCode(e: unknown): AppErrorCode | null {
  if (e instanceof RpcError) return e.code;
  const message = asErrorLike(e)?.message;
  if (typeof message !== 'string') return null;
  const code = message.trim();
  return (APP_ERROR_CODES as readonly string[]).includes(code) ? (code as AppErrorCode) : null;
}

/** Wraps a PostgREST error object as an RpcError (keeps the detail for logs, never shown raw). */
export function toRpcError(e: unknown): RpcError {
  if (e instanceof RpcError) return e;
  const like = asErrorLike(e);
  const detail = like?.details ?? like?.detail;
  const message = typeof like?.message === 'string' ? like.message : String(e);
  return new RpcError(appErrorCode(e), typeof detail === 'string' ? detail : null, message);
}

/**
 * Should a write be tried again later? Yes for network/unknown failures and RATE_LIMITED; no for an
 * app error the server will give again (NOT_AUTHORIZED, VALIDATION_FAILED, …).
 */
export function isRetryable(e: unknown): boolean {
  const code = appErrorCode(e);
  return code === null || code === 'RATE_LIMITED';
}

/** i18n key for a user-facing message: what went wrong and how to fix it. */
export function errorMessageKey(e: unknown): string {
  switch (appErrorCode(e)) {
    case 'NOT_AUTHORIZED':
      return 'errors.notAuthorized';
    case 'VALIDATION_FAILED':
    case 'COUNT_MODE_MISMATCH':
      return 'errors.validation';
    case 'QUEUE_VERSION_CONFLICT':
      return 'errors.queueChanged';
    case 'INVALID_STATUS_TRANSITION':
      return 'errors.statusChanged';
    case 'OUT_OF_RANGE_TIMESTAMP':
      return 'errors.tooLate';
    case 'RATE_LIMITED':
      return 'errors.rateLimited';
    default:
      return 'errors.network';
  }
}

/** Throws an RpcError for a supabase-js `{ error }` result; returns data otherwise. */
export function unwrap<T>(result: { data: T; error: unknown }): T {
  if (result.error) throw toRpcError(result.error);
  return result.data;
}
