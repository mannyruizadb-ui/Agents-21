import { describe, expect, it } from 'vitest';
import { isOffQueueReason, needsOffQueueReason, OFF_QUEUE_REASONS } from './offQueue';

describe('needsOffQueueReason', () => {
  it('asks only when a hand-picked group differs from the queue next', () => {
    expect(needsOffQueueReason('g2', 'q1', 'g1')).toBe(true);
    expect(needsOffQueueReason('g1', 'q1', 'g1')).toBe(false);
  });
  it('never asks when following the queue or when nothing is queued', () => {
    expect(needsOffQueueReason(null, 'q1', 'g1')).toBe(false);
    expect(needsOffQueueReason('g2', null, null)).toBe(false);
  });
});

describe('isOffQueueReason', () => {
  it('accepts the four codes in the database order only', () => {
    expect(OFF_QUEUE_REASONS).toEqual(['not_ready', 'wrong_washer', 'urgent', 'other']);
    expect(isOffQueueReason('urgent')).toBe(true);
    expect(isOffQueueReason('lazy')).toBe(false);
    expect(isOffQueueReason(undefined)).toBe(false);
  });
});
