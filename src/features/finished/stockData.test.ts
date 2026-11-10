import { beforeEach, describe, expect, it, vi } from 'vitest';

const rpc = vi.fn();
vi.mock('../../lib/supabase', () => ({ supabase: { rpc: (...a: unknown[]) => rpc(...a) } }));

const { checkOverStock } = await import('./stockData');

describe('finished_goods_over_stock check', () => {
  beforeEach(() => {
    rpc.mockReset();
  });

  it('asks the server with the total after the add', async () => {
    rpc.mockResolvedValue({ data: true, error: null });
    await expect(checkOverStock('item-1', 12_000)).resolves.toBe(true);
    expect(rpc).toHaveBeenCalledWith('finished_goods_over_stock', {
      p_item_type_id: 'item-1',
      p_total_after: 12_000,
    });
    rpc.mockResolvedValue({ data: false, error: null });
    await expect(checkOverStock('item-1', 10)).resolves.toBe(false);
  });

  it('an error or a thrown request = unknown (the check is skipped, saving not blocked)', async () => {
    rpc.mockResolvedValue({ data: null, error: { message: 'NOT_AUTHORIZED' } });
    await expect(checkOverStock('item-1', 10)).resolves.toBeNull();
    rpc.mockRejectedValue(new TypeError('Failed to fetch'));
    await expect(checkOverStock('item-1', 10)).resolves.toBeNull();
  });

  it('no answer in time = unknown', async () => {
    rpc.mockReturnValue(new Promise(() => {}));
    await expect(checkOverStock('item-1', 10, 20)).resolves.toBeNull();
  });
});
