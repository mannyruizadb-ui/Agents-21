import { describe, expect, it } from 'vitest';
import { cleanReason, describeVoid, groupMapFromLines, parseKeptItems } from './deliveryVoid';

describe('deliveryVoid', () => {
  const groups = groupMapFromLines(
    ['q1', 'q2', 'q3'],
    [{ washGroupId: 'g1' }, { washGroupId: 'g2' }, { washGroupId: 'g3' }],
  );

  it('maps queue items to groups by line order (only when the counts match)', () => {
    expect(groups.get('q2')).toBe('g2');
    expect(groupMapFromLines(['q1'], [{ washGroupId: 'a' }, { washGroupId: 'b' }]).size).toBe(0);
  });

  it('describes cancelled and kept items', () => {
    const v = describeVoid(
      {
        delivery_id: 'd',
        cancelled_item_ids: ['q1', 'q3'],
        kept_items: [{ queue_item_id: 'q2', status: 'in_progress', loads_started: 1 }],
        duplicate: false,
      },
      groups,
    );
    expect(v).toEqual({
      deliveryId: 'd',
      duplicate: false,
      cancelled: ['g1', 'g3'],
      kept: [{ queueItemId: 'q2', status: 'in_progress', loadsStarted: 1, washGroupId: 'g2' }],
    });
  });

  it('unknown items and a repeat call', () => {
    const v = describeVoid(
      { delivery_id: 'd', cancelled_item_ids: null, kept_items: null, duplicate: true },
      new Map(),
    );
    expect(v).toMatchObject({ duplicate: true, cancelled: [], kept: [] });
    expect(
      describeVoid(
        { delivery_id: 'd', cancelled_item_ids: ['zz'], kept_items: [], duplicate: false },
        new Map(),
      ).cancelled,
    ).toEqual([null]);
  });

  it('skips unreadable kept items', () => {
    expect(
      parseKeptItems([{ status: 'done' }, 'x', { queue_item_id: 'q', status: 'done' }]),
    ).toEqual([{ queueItemId: 'q', status: 'done', loadsStarted: 0 }]);
  });

  it('cleans the reason', () => {
    expect(cleanReason('   ')).toBeNull();
    expect(cleanReason(' wrong\ncustomer ')).toBe('wrong customer');
    expect(cleanReason('x'.repeat(300))).toHaveLength(200);
  });
});
