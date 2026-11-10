import { useQuery } from '@tanstack/react-query';
import { supabase } from '../../lib/supabase';
import { unwrap } from '../washroom/rpcError';

// Stock owned per item is OWNER ONLY (owner 2026-11-10): the DB revokes column SELECT on
// item_types.stock_qty, so nothing in src/ selects it from the table. The owner reads it through
// get_item_stock; the finished-goods "more than you own" check asks finished_goods_over_stock (owner
// and managers), which answers yes/no without revealing the number.

export interface ItemStockRow {
  item_type_id: string;
  /** null = not set (the generated type says number; the SQL returns null for no stock). */
  stock_qty: number | null;
}

export const stockKeys = {
  all: ['item-stock'] as const,
  stock: (plantId: string) => ['item-stock', plantId] as const,
};

/** item id → stock owned. Owner only: pass enabled=false for anyone else (the RPC refuses them). */
export function useItemStock(plantId: string | undefined, enabled: boolean) {
  return useQuery({
    queryKey: stockKeys.stock(plantId ?? ''),
    enabled: !!plantId && enabled,
    queryFn: async (): Promise<Map<string, number>> => {
      const rows: ItemStockRow[] =
        unwrap(await supabase.rpc('get_item_stock', { p_plant_id: plantId ?? '' })) ?? [];
      const map = new Map<string, number>();
      for (const r of rows) if (r.stock_qty !== null) map.set(r.item_type_id, r.stock_qty);
      return map;
    },
    staleTime: 5 * 60_000,
  });
}

/** How long the save waits for the over-stock answer before skipping the check. */
export const OVER_STOCK_TIMEOUT_MS = 3_000;

/**
 * Would this shift's total after the add be more than the plant owns? null = unknown (offline, an
 * error, a timeout, or no stock set): the caller then skips the stock check and never blocks saving.
 */
export async function checkOverStock(
  itemTypeId: string,
  totalAfter: number,
  timeoutMs: number = OVER_STOCK_TIMEOUT_MS,
): Promise<boolean | null> {
  if (typeof navigator !== 'undefined' && navigator.onLine === false) return null;
  let timer: ReturnType<typeof setTimeout> | undefined;
  const timeout = new Promise<null>((resolve) => {
    timer = setTimeout(() => resolve(null), timeoutMs);
  });
  const ask = (async () => {
    try {
      const r = await supabase.rpc('finished_goods_over_stock', {
        p_item_type_id: itemTypeId,
        p_total_after: totalAfter,
      });
      return r.error || typeof r.data !== 'boolean' ? null : r.data;
    } catch {
      return null;
    }
  })();
  try {
    return await Promise.race([ask, timeout]);
  } finally {
    clearTimeout(timer);
  }
}

/**
 * Save the stock owned of one item (owner only): a plain column update with NO .select() (RETURNING
 * would need the revoked column SELECT). The DB has no set_item_stock RPC (2026-11-10).
 */
export async function saveItemStock(itemTypeId: string, stock: number | null): Promise<void> {
  const { error } = await supabase
    .from('item_types')
    .update({ stock_qty: stock })
    .eq('id', itemTypeId);
  if (error) throw error;
}
