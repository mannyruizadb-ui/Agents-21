// "Dirty work out there" (owner 2026-11-09, app review §3 and items 1–2). ONE pure selector for every
// screen that says how much dirty work is waiting: the owner's Home card, the manager's Home tile, the
// Estimates summary and the Queue header. They all read the numbers from here, so they never disagree.
//
// Rules (review §3):
// - The category is the line, the groups are the detail. Fixed order: mats, napkins, tablecloths,
//   towels & aprons, sheets, mops, other. Categories with nothing waiting are left out.
// - Units as entered: a category adds amounts per unit only ("7½ baskets", or "2 baskets + 1 load");
//   baskets are never added to bins.
// - ≈ loads are WHOLE: Math.ceil per group, then summed. A group with no factor for its container is
//   "loads unknown" (never 0) and a total with any unknown reads "≈ N+".
// - Time once, for everything in the card: Σ(whole loads × the group's cycle minutes) ÷ the working
//   washers' capacity, never less than the longest single cycle waiting. Rounded to 5 min.
// - Outside customers (AA Linen) are separate, from their open queue items (deliveries go straight
//   into the queue, so their estimates would double count).
// Never weights, never names.

import type { Category } from '../estimates/categories';

/** Display order of the categories (review §3). */
export const DIRTY_CATEGORY_ORDER: readonly Category[] = [
  'mats',
  'napkins',
  'tablecloths',
  'towels_aprons',
  'sheets',
  'mops',
  'other',
];

/** Units in the order they are listed inside a line ("2 baskets + 1 bin + 3 loads"). */
const UNIT_ORDER = ['basket', 'bin', 'load', 'pack', 'piece'] as const;

export interface DirtyGroupInput {
  id: string;
  name: string;
  name_i18n: unknown;
  color_hex: string | null;
  wash_formula_id: string | null;
  customer_id: string | null;
  loads_per_basket?: number | null;
  loads_per_bin?: number | null;
}

export interface DirtyEstimateInput {
  qty: number;
  unit: string;
  /** app.to_loads(qty) from the database; null = the container has no factor. */
  qty_loads: number | null;
}

/** An open queue row (get_queue), only the columns used here. */
export interface DirtyQueueInput {
  id: string;
  wash_group_id: string;
  status: string;
  qty: number | null;
  unit: string | null;
  qty_loads?: number | null;
  loads_needed?: number | null;
  loads_remaining: number | null;
  is_rewash?: boolean | null;
}

export interface UnitAmount {
  unit: string;
  qty: number;
}

export interface GroupLine {
  id: string;
  name: string;
  nameI18n: unknown;
  color: string | null;
  /** Amounts as entered (one per unit). */
  amounts: UnitAmount[];
  /** Whole ≈ loads; null = loads unknown (no factor). */
  loads: number | null;
  /** Some of the group's amount has no load number (only for groups with several queue items). */
  partlyUnknown: boolean;
  cycleMinutes: number | null;
}

export interface CategoryLine {
  category: Category;
  amounts: UnitAmount[];
  /** Sum of the known whole loads. */
  loads: number;
  /** Groups (or items) whose loads are unknown. */
  unknown: number;
  groups: GroupLine[];
  /** Share of the section's known loads, 0–1 (for the one neutral bar). */
  share: number;
}

export interface Section {
  categories: CategoryLine[];
  loads: number;
  unknown: number;
}

export interface CustomerSection extends Section {
  customerId: string;
  /** Open queue items of the customer's groups. */
  items: number;
}

export interface WashTime {
  /** ≈ minutes to wash everything in the card on the washers up now; null = can't tell. */
  minutes: number | null;
  /** Why minutes is null: no working washer, or nothing has a cycle time. */
  reason: 'noWashers' | 'noTime' | null;
  /** Working washers (count, for "on 6 washers"). */
  washers: number;
  /** Groups with loads but no cycle time: in the loads, missing from the time. */
  noTime: number;
  /** Loads unknown anywhere: the time is a lower bound. */
  partial: boolean;
}

export interface DirtyWork {
  ours: Section;
  customers: CustomerSection[];
  rewash: { items: number; loads: number; unknown: number };
  /** Our groups without any estimate yet. */
  notEstimated: number;
  /** Our groups with an estimate (0 included). */
  estimated: number;
  time: WashTime;
}

export interface DirtyWorkInput {
  groups: readonly DirtyGroupInput[];
  estimates: ReadonlyMap<string, DirtyEstimateInput>;
  /** Open queue rows of the washroom (AA work and rewash come from here). Omit when not loaded. */
  queue?: readonly DirtyQueueInput[];
  categoryOf: ReadonlyMap<string, Category>;
  cycleMinutesOf: (formulaId: string | null) => number | null | undefined;
  /** Working washers: count and capacity (sum of load factors; Washer 6 = 1.19). */
  washers: { count: number; capacity: number };
  /** Customer of a group (falls back to the group's customer_id). */
  customerOf?: (groupId: string) => string | null;
}

const isContainer = (unit: string | null | undefined) => unit === 'basket' || unit === 'bin';

/** Whole loads for an approximate number: 2.0 → 2, 2.01 → 3 (cents of float noise ignored). */
export function wholeLoads(loads: number): number {
  return Math.max(0, Math.ceil(Math.round(loads * 100) / 100));
}

/**
 * Loads still to wash for a queue item; null = unknown (the container has no factor). Fixes the
 * "≈ 0 loads left" bug (review §5 item 2): the database's loads_remaining is
 * greatest(loads_needed − started, 0), and greatest() ignores a null loads_needed, so an item without
 * a factor reads 0. Piece / pack items have no load count: null.
 */
export function queueLoadsLeft(q: {
  unit: string | null;
  qty?: number | null;
  qty_loads?: number | null;
  loads_needed?: number | null;
  loads_remaining: number | null;
}): number | null {
  if (q.unit === 'piece' || q.unit === 'pack') return null;
  if (q.loads_remaining === null || q.loads_remaining === undefined) return null;
  if (q.loads_needed === null) return null;
  if (isContainer(q.unit) && q.qty_loads === null && Number(q.qty ?? 0) > 0) return null;
  return Math.max(0, Number(q.loads_remaining));
}

/**
 * The same for the washer board's NEXT (get_washroom_board has no loads_needed): unknown when the
 * group has no factor for the item's container.
 */
export function boardLoadsLeft(
  loadsRemaining: number | null | undefined,
  unit: string | null | undefined,
  group: { loads_per_basket?: number | null; loads_per_bin?: number | null } | undefined,
): number | null {
  if (loadsRemaining === null || loadsRemaining === undefined) return null;
  if (unit === 'piece' || unit === 'pack') return null;
  if (isContainer(unit) && group) {
    const f = unit === 'bin' ? group.loads_per_bin : group.loads_per_basket;
    if (!f || Number(f) <= 0) return null;
  }
  return Math.max(0, Number(loadsRemaining));
}

function addAmount(list: UnitAmount[], unit: string, qty: number): void {
  const cur = list.find((a) => a.unit === unit);
  if (cur) cur.qty = Math.round((cur.qty + qty) * 100) / 100;
  else list.push({ unit, qty });
}

function sortAmounts(list: UnitAmount[]): UnitAmount[] {
  const rank = (u: string) => {
    const i = (UNIT_ORDER as readonly string[]).indexOf(u);
    return i < 0 ? UNIT_ORDER.length : i;
  };
  return list.sort((a, b) => rank(a.unit) - rank(b.unit) || a.unit.localeCompare(b.unit));
}

/** Builds the category lines of one section from its group lines (groups keep their input order). */
function toSection(lines: readonly (GroupLine & { category: Category; unknownCount: number })[]) {
  const by = new Map<Category, CategoryLine>();
  for (const l of lines) {
    let c = by.get(l.category);
    if (!c) {
      c = { category: l.category, amounts: [], loads: 0, unknown: 0, groups: [], share: 0 };
      by.set(l.category, c);
    }
    for (const a of l.amounts) addAmount(c.amounts, a.unit, a.qty);
    c.loads += l.loads ?? 0;
    c.unknown += l.unknownCount;
    c.groups.push({
      id: l.id,
      name: l.name,
      nameI18n: l.nameI18n,
      color: l.color,
      amounts: l.amounts,
      loads: l.loads,
      partlyUnknown: l.partlyUnknown,
      cycleMinutes: l.cycleMinutes,
    });
  }
  const categories = DIRTY_CATEGORY_ORDER.flatMap((cat) => {
    const c = by.get(cat);
    if (!c) return [];
    sortAmounts(c.amounts);
    return [c];
  });
  const loads = categories.reduce((n, c) => n + c.loads, 0);
  for (const c of categories) c.share = loads > 0 ? c.loads / loads : 0;
  return { categories, loads, unknown: categories.reduce((n, c) => n + c.unknown, 0) };
}

/** The one selector. Pure: same input, same numbers on every screen. */
export function dirtyWork(input: DirtyWorkInput): DirtyWork {
  const customerOf = (id: string) => {
    const fromLookup = input.customerOf?.(id);
    if (fromLookup) return fromLookup;
    return input.groups.find((g) => g.id === id)?.customer_id ?? null;
  };
  const cycleOf = (g: DirtyGroupInput) => {
    const m = input.cycleMinutesOf(g.wash_formula_id);
    return m && m > 0 ? m : null;
  };
  const categoryOf = (id: string): Category => input.categoryOf.get(id) ?? 'other';

  // Ours: the current estimate of each of our groups, above 0.
  const own = input.groups.filter((g) => !customerOf(g.id));
  const ourLines: (GroupLine & { category: Category; unknownCount: number })[] = [];
  let estimated = 0;
  for (const g of own) {
    const e = input.estimates.get(g.id);
    if (!e) continue;
    estimated += 1;
    const qty = Number(e.qty);
    if (!(qty > 0)) continue;
    const loads =
      e.unit === 'load'
        ? wholeLoads(qty)
        : e.qty_loads === null || e.qty_loads === undefined
          ? null
          : wholeLoads(Number(e.qty_loads));
    ourLines.push({
      id: g.id,
      name: g.name,
      nameI18n: g.name_i18n,
      color: g.color_hex,
      amounts: [{ unit: e.unit, qty }],
      loads,
      partlyUnknown: false,
      cycleMinutes: cycleOf(g),
      category: categoryOf(g.id),
      unknownCount: loads === null ? 1 : 0,
    });
  }
  const ours = toSection(ourLines);

  // Outside customers and rewash: from the open queue.
  const open = (input.queue ?? []).filter((q) => q.status !== 'done' && q.status !== 'cancelled');
  const groupById = new Map(input.groups.map((g) => [g.id, g]));
  const byCustomer = new Map<
    string,
    { items: number; lines: Map<string, GroupLine & { category: Category; unknownCount: number }> }
  >();
  const rewash = { items: 0, loads: 0, unknown: 0 };
  for (const q of open) {
    const cid = customerOf(q.wash_group_id);
    const left = queueLoadsLeft(q);
    if (!cid) {
      if (q.is_rewash) {
        rewash.items += 1;
        if (left === null) rewash.unknown += 1;
        else rewash.loads += left;
      }
      continue;
    }
    let c = byCustomer.get(cid);
    if (!c) {
      c = { items: 0, lines: new Map() };
      byCustomer.set(cid, c);
    }
    c.items += 1;
    const g = groupById.get(q.wash_group_id);
    let line = c.lines.get(q.wash_group_id);
    if (!line) {
      line = {
        id: q.wash_group_id,
        name: g?.name ?? '',
        nameI18n: g?.name_i18n ?? null,
        color: g?.color_hex ?? null,
        amounts: [],
        loads: null,
        partlyUnknown: false,
        cycleMinutes: g ? cycleOf(g) : null,
        category: categoryOf(q.wash_group_id),
        unknownCount: 0,
      };
      c.lines.set(q.wash_group_id, line);
    }
    if (q.unit && q.qty !== null && Number(q.qty) > 0)
      addAmount(line.amounts, q.unit, Number(q.qty));
    if (left === null) line.unknownCount += 1;
    else line.loads = (line.loads ?? 0) + left;
  }
  // Every customer with a wash group gets a section, even with nothing waiting ("nothing waiting").
  for (const g of input.groups) {
    const cid = customerOf(g.id);
    if (cid && !byCustomer.has(cid)) byCustomer.set(cid, { items: 0, lines: new Map() });
  }
  const customers: CustomerSection[] = [...byCustomer.entries()].map(([customerId, c]) => {
    const lines = [...c.lines.values()].map((l) => ({
      ...l,
      amounts: sortAmounts(l.amounts),
      // Some items of the group have a load number and some don't: "≈ N+" for the group.
      partlyUnknown: l.loads !== null && l.unknownCount > 0,
    }));
    return { customerId, items: c.items, ...toSection(lines) };
  });

  // Time: everything in the card (ours + customers' known loads).
  let washerMinutes = 0;
  let longest = 0;
  let noTime = 0;
  let anyLoads = false;
  for (const section of [ours, ...customers])
    for (const cat of section.categories)
      for (const g of cat.groups) {
        if (!g.loads) continue;
        anyLoads = true;
        if (g.cycleMinutes === null) {
          noTime += 1;
          continue;
        }
        washerMinutes += g.loads * g.cycleMinutes;
        longest = Math.max(longest, g.cycleMinutes);
      }
  const partial = ours.unknown > 0 || customers.some((c) => c.unknown > 0);
  const washers = Math.max(0, input.washers.count);
  const capacity = input.washers.capacity;
  let minutes: number | null;
  let reason: WashTime['reason'] = null;
  if (!anyLoads) minutes = 0;
  else if (washerMinutes === 0) {
    minutes = null;
    reason = 'noTime';
  } else if (!(capacity > 0) || washers === 0) {
    minutes = null;
    reason = 'noWashers';
  } else minutes = Math.max(washerMinutes / capacity, longest);

  return {
    ours,
    customers,
    rewash,
    notEstimated: own.length - estimated,
    estimated,
    time: { minutes, reason, washers, noTime, partial },
  };
}

/** Minutes rounded to 5 (anything above 0 is at least 5 min): { h, m }. */
export function roundedTime(minutes: number): { h: number; m: number } {
  const total = minutes > 0 ? Math.max(5, Math.round(minutes / 5) * 5) : 0;
  return { h: Math.floor(total / 60), m: total % 60 };
}

/** Minutes the rounded time stands for (for "Done around"). */
export function roundedMinutes(minutes: number): number {
  const { h, m } = roundedTime(minutes);
  return h * 60 + m;
}
