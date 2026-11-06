import { describe, expect, it } from 'vitest';
import {
  appErrorCode,
  errorMessageKey,
  isRetryable,
  RpcError,
  tapRejectedKey,
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

describe('machine down and late taps', () => {
  it('never retries MACHINE_DOWN or OUT_OF_RANGE_TIMESTAMP (kept on screen as not recorded)', () => {
    expect(isRetryable({ message: 'MACHINE_DOWN' })).toBe(false);
    expect(isRetryable({ message: 'OUT_OF_RANGE_TIMESTAMP' })).toBe(false);
    expect(errorMessageKey({ message: 'MACHINE_DOWN' })).toBe('errors.machineDown');
  });
  it('words refused taps by reason', () => {
    expect(tapRejectedKey('OUT_OF_RANGE_TIMESTAMP')).toBe('station.rejectTooLate');
    expect(tapRejectedKey('MACHINE_DOWN')).toBe('station.rejectDown');
    expect(tapRejectedKey('VALIDATION_FAILED')).toBe('errors.validation');
  });
});

describe('WASHER_RUNNING (owner 2026-11-06)', () => {
  it('is an app error that is not retried and has its own wording', async () => {
    const { appErrorCode, isRetryable, errorMessageKey, tapRejectedKey } =
      await import('./rpcError');
    const e = { message: 'WASHER_RUNNING', details: 'machine_id: still running until …' };
    expect(appErrorCode(e)).toBe('WASHER_RUNNING');
    expect(isRetryable(e)).toBe(false);
    expect(errorMessageKey(e)).toBe('errors.washerRunning');
    expect(tapRejectedKey('WASHER_RUNNING')).toBe('station.rejectRunning');
  });
});
