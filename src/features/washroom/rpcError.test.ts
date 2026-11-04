import { describe, expect, it } from 'vitest';
import {
  appErrorCode,
  errorMessageKey,
  isRetryable,
  RpcError,
  toRpcError,
  unwrap,
} from './rpcError';

describe('rpcError', () => {
  it('reads the PRD code from a PostgREST error message', () => {
    expect(appErrorCode({ message: 'VALIDATION_FAILED', details: 'x', code: 'P0001' })).toBe(
      'VALIDATION_FAILED',
    );
    expect(appErrorCode({ message: 'TypeError: Failed to fetch', code: '' })).toBeNull();
    expect(appErrorCode('boom')).toBeNull();
    expect(appErrorCode(null)).toBeNull();
  });

  it('retries network failures and RATE_LIMITED, not app errors', () => {
    expect(isRetryable({ message: 'TypeError: Failed to fetch' })).toBe(true);
    expect(isRetryable({ message: 'RATE_LIMITED' })).toBe(true);
    expect(isRetryable({ message: 'NOT_AUTHORIZED' })).toBe(false);
    expect(isRetryable(new RpcError('VALIDATION_FAILED', null, 'VALIDATION_FAILED'))).toBe(false);
  });

  it('maps codes to message keys', () => {
    expect(errorMessageKey({ message: 'QUEUE_VERSION_CONFLICT' })).toBe('errors.queueChanged');
    expect(errorMessageKey({ message: 'OUT_OF_RANGE_TIMESTAMP' })).toBe('errors.tooLate');
    expect(errorMessageKey(new Error('offline'))).toBe('errors.network');
  });

  it('unwraps data and throws RpcError with the detail', () => {
    expect(unwrap({ data: 5, error: null })).toBe(5);
    try {
      unwrap({ data: null, error: { message: 'NOT_AUTHORIZED', details: 'no role' } });
      expect.unreachable();
    } catch (e) {
      expect(e).toBeInstanceOf(RpcError);
      expect((e as RpcError).code).toBe('NOT_AUTHORIZED');
      expect((e as RpcError).detail).toBe('no role');
    }
    expect(toRpcError({ message: 'x' }).code).toBeNull();
  });
});
