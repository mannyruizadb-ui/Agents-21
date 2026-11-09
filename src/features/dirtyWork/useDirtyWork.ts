import { useCustomerLookup } from '../customers/useCustomerLookup';
import {
  useCurrentEstimates,
  useEstimateGroups,
  useFormulaMinutes,
  useGroupCategories,
  useWasherCapacity,
} from '../estimates/estimatesData';
import { pickArea, useAreas, useQueue } from '../washroom/washroomData';
import { dirtyWork, type DirtyEstimateInput, type DirtyWork } from './dirtyWork';

/**
 * Reads everything the dirty-work selector needs and runs it. Every screen that says how much dirty
 * work is waiting goes through here (owner Home card, manager Home tile, Estimates, Queue header), so
 * the numbers can't disagree. The queries are the ones those screens already used (shared cache).
 *
 * `estimates` replaces the saved estimates (the Estimates screen passes its unsaved changes merged
 * in, so its summary follows what is being typed).
 */
export function useDirtyWork(
  plantId: string | undefined,
  opts: { estimates?: ReadonlyMap<string, DirtyEstimateInput> } = {},
) {
  const areas = useAreas();
  const washroom = pickArea(areas.data, 'washroom');
  const groups = useEstimateGroups(plantId);
  const categories = useGroupCategories(plantId);
  const current = useCurrentEstimates(plantId);
  const formulas = useFormulaMinutes(plantId);
  const capacity = useWasherCapacity(plantId);
  const queue = useQueue(washroom?.id);
  const lookup = useCustomerLookup();

  const ready = groups.isSuccess && current.isSuccess && formulas.isSuccess;
  const data: DirtyWork | null = ready
    ? dirtyWork({
        groups: groups.data,
        estimates: opts.estimates ?? current.data,
        queue: queue.data,
        // The category column is read apart: if it fails, everything is listed under "Other".
        categoryOf: categories.data ?? new Map(),
        cycleMinutesOf: (id) => (id ? (formulas.data.get(id) ?? null) : null),
        washers: {
          count: capacity.data?.washers ?? 0,
          capacity: capacity.data?.capacity ?? 0,
        },
        customerOf: (id) => lookup(id)?.customerId ?? null,
      })
    : null;
  // An error only counts when there is nothing to show (a failed refresh keeps the old numbers).
  const failed =
    (groups.isError && !groups.data) ||
    (current.isError && !current.data) ||
    (formulas.isError && !formulas.data);
  const error = failed ? (groups.error ?? current.error ?? formulas.error) : null;
  // One wash group per customer, to name the customer ("AA Linen") even when nothing is waiting.
  const customerGroupId = new Map<string, string>();
  for (const g of groups.data ?? []) {
    const cid = lookup(g.id)?.customerId ?? g.customer_id;
    if (cid && !customerGroupId.has(cid)) customerGroupId.set(cid, g.id);
  }
  return {
    data,
    customerGroupId,
    ready,
    error,
    /** The time needs the working washers; until they load it shows "…". */
    capacityReady: capacity.isSuccess,
    /** AA and rewash come from the queue; until it loads they are left out. */
    queueReady: queue.isSuccess,
    current,
    queue,
    capacity,
  };
}
