import { describe, expect, it } from 'vitest';
import {
  barPct,
  contrast,
  customerWork,
  ownGroups,
  estimateAges,
  finishedToday,
  loadsToday,
  needsOutline,
  topN,
  washerCounts,
  washerSegments,
  workByGroup,
  type GroupInput,
} from './dashboardLogic';

const g = (id: string, formula: string | null, name = id): GroupInput => ({
  id,
  name,
  name_i18n: null,
  color_hex: '#DC2626',
  wash_formula_id: formula,
});
const minutes = new Map<string, number | null>([
  ['f40', 40],
  ['f60', 60],
]);
const cycleOf = (id: string | null) => (id ? (minutes.get(id) ?? null) : null);

describe('workByGroup', () => {
  it('spreads loads × cycle minutes over the washer capacity and sorts by time', () => {
    const rows = workByGroup(
      [g('a', 'f40'), g('b', 'f60'), g('c', null), g('d', 'f40'), g('e', 'f40')],
      new Map([
        ['a', { qty: 3, qty_loads: 3 }], // 2 washer-h
        ['b', { qty: 2, qty_loads: 4 }], // 4 washer-h
        ['c', { qty: 5, qty_loads: 5 }], // no time
        ['d', { qty: 0, qty_loads: null }], // nothing waiting: left out
        ['e', { qty: 2, qty_loads: null }], // no factor: loads unknown
      ]),
      cycleOf,
      2,
      (id) => (id === 'b' ? 'aa' : null),
    );
    expect(rows.map((r) => r.id)).toEqual(['b', 'a', 'c', 'e']);
    expect(rows[0]).toMatchObject({ loads: 4, washerHours: 4, hours: 2, customerId: 'aa' });
    expect(rows[1]).toMatchObject({ hours: 1 });
    expect(rows[2]).toMatchObject({ loads: 5, hours: null });
    expect(rows[3]).toMatchObject({ loads: null, hours: null });
  });

  it('gives no hours without a working washer but keeps the loads', () => {
    const [row] = workByGroup(
      [g('a', 'f60')],
      new Map([['a', { qty: 1, qty_loads: 1 }]]),
      cycleOf,
      0,
    );
    expect(row).toMatchObject({ loads: 1, washerHours: 1, hours: null });
  });
});

describe('estimateAges', () => {
  it('finds the newest and oldest and counts old ones with work waiting', () => {
    const a = estimateAges([
      { entered_at: '2026-11-09T10:00:00Z', freshness: 'ok', qty: 2 },
      { entered_at: '2026-11-09T06:00:00Z', freshness: 'red', qty: 1 },
      { entered_at: '2026-11-09T05:00:00Z', freshness: 'amber', qty: 0 },
    ]);
    expect(a).toEqual({
      newest: Date.parse('2026-11-09T10:00:00Z'),
      oldest: Date.parse('2026-11-09T05:00:00Z'),
      old: 1,
    });
  });
  it('is null with no estimates', () => {
    expect(estimateAges([])).toBeNull();
  });
});

describe('washer counts', () => {
  it('down wins; unknown counts as idle', () => {
    const c = washerCounts([
      { isDown: false, status: 'running' },
      { isDown: true, status: 'running' },
      { isDown: false, status: 'ready' },
      { isDown: false, status: 'unknown' },
      { isDown: false, status: 'idle' },
      { isDown: false, status: 'running' },
    ]);
    expect(c).toEqual({ running: 2, ready: 1, idle: 2, down: 1, total: 6 });
    expect(washerSegments(c).map((s) => [s.state, s.count])).toEqual([
      ['running', 2],
      ['ready', 1],
      ['idle', 2],
      ['down', 1],
    ]);
  });
  it('drops empty states and has no segments without washers', () => {
    const c = washerCounts([{ isDown: false, status: 'running' }]);
    expect(washerSegments(c)).toEqual([{ state: 'running', count: 1, pct: 100 }]);
    expect(washerSegments(washerCounts([]))).toEqual([]);
  });
});

describe('loadsToday', () => {
  it('totals standard and rewash loads; groups with loads only, most first', () => {
    const base = { production_date: '2026-11-08', wash_group_name_i18n: null, color_hex: null };
    const r = loadsToday([
      {
        ...base,
        wash_group_id: 'a',
        wash_group_name: 'A',
        loads_run: 3,
        standard_loads: 3,
        rewash_loads: 0,
      },
      {
        ...base,
        wash_group_id: 'b',
        wash_group_name: 'B',
        loads_run: 4,
        standard_loads: 4.76,
        rewash_loads: 1,
      },
      {
        ...base,
        wash_group_id: 'c',
        wash_group_name: 'C',
        loads_run: 0,
        standard_loads: 0,
        rewash_loads: 0,
      },
      {
        ...base,
        wash_group_id: 'd',
        wash_group_name: 'D',
        loads_run: 1,
        standard_loads: 0,
        rewash_loads: 1,
      },
    ]);
    expect(r.productionDate).toBe('2026-11-08');
    expect(r.standard).toBe(7.76);
    expect(r.rewash).toBe(2);
    expect(r.groups.map((x) => x.id)).toEqual(['b', 'a', 'd']);
  });
  it('is empty with no rows', () => {
    expect(loadsToday([])).toEqual({ productionDate: null, standard: 0, rewash: 0, groups: [] });
  });
});

describe('finishedToday', () => {
  it('sums pieces per item, leaves voided entries out, sorts by pieces', () => {
    const e = (id: string, pieces: number, voided: string | null = null) => ({
      item_type_id: id,
      item_name: id.toUpperCase(),
      item_name_i18n: null,
      pieces,
      voided_at: voided,
    });
    const r = finishedToday([
      e('napkin', 500),
      e('sheet', 300),
      e('napkin', 250),
      e('sheet', 900, '2026-11-09T01:00:00Z'),
    ]);
    expect(r.pieces).toBe(1050);
    expect(r.entries).toBe(3);
    expect(r.voided).toBe(1);
    expect(r.items).toEqual([
      { id: 'napkin', name: 'NAPKIN', nameI18n: null, pieces: 750 },
      { id: 'sheet', name: 'SHEET', nameI18n: null, pieces: 300 },
    ]);
  });
});

describe('customerWork', () => {
  const customerOf = (id: string) => (id.startsWith('aa') ? 'AA' : null);
  const formula: Record<string, number | null> = { aa1: 60, aa2: 40, own: 60, aa3: null };
  const cycleOfGroup = (id: string) => formula[id] ?? null;

  it('counts open queue loads not started per customer, with ≈ hours on the washers', () => {
    const [c, ...rest] = customerWork(
      [
        { wash_group_id: 'aa1', status: 'queued', loads_remaining: 2 },
        { wash_group_id: 'aa2', status: 'in_progress', loads_remaining: 3 },
        { wash_group_id: 'aa2', status: 'done', loads_remaining: 0 },
        { wash_group_id: 'aa1', status: 'cancelled', loads_remaining: 5 },
        { wash_group_id: 'own', status: 'queued', loads_remaining: 4 },
      ],
      customerOf,
      cycleOfGroup,
      2,
    );
    expect(rest).toEqual([]);
    expect(c).toEqual({
      customerId: 'AA',
      queueItems: 2,
      queueLoads: 5,
      queueWithoutCount: 0,
      queueHours: 2, // (2×60 + 3×40) / 60 / 2
    });
  });

  it('has unknown hours when an item has no load count, a group no formula, or no washers', () => {
    const q = (id: string, n: number | null) => ({
      wash_group_id: id,
      status: 'queued',
      loads_remaining: n,
    });
    const noCount = customerWork([q('aa1', 2), q('aa2', null)], customerOf, cycleOfGroup, 2)[0];
    expect(noCount?.queueWithoutCount).toBe(1);
    expect(noCount?.queueLoads).toBe(2);
    expect(noCount?.queueHours).toBeNull();
    expect(customerWork([q('aa3', 2)], customerOf, cycleOfGroup, 2)[0]?.queueHours).toBeNull();
    expect(customerWork([q('aa1', 2)], customerOf, cycleOfGroup, 0)[0]?.queueHours).toBeNull();
  });

  it('never uses estimates, and ownGroups leaves customer groups out of the totals', () => {
    expect(customerWork([], customerOf)).toEqual([]);
    expect(ownGroups([{ id: 'aa1' }, { id: 'own' }], customerOf)).toEqual([{ id: 'own' }]);
  });
});

describe('chart helpers', () => {
  it('topN splits shown and the rest', () => {
    expect(topN([1, 2, 3], 2)).toEqual({ shown: [1, 2], rest: 1 });
    expect(topN([1], 5)).toEqual({ shown: [1], rest: 0 });
  });
  it('barPct scales to the max with a visible minimum', () => {
    expect(barPct(5, 10)).toBe(50);
    expect(barPct(0.01, 10)).toBe(2);
    expect(barPct(0, 10)).toBe(0);
    expect(barPct(3, 0)).toBe(0);
  });
  it('outlines goods colors that vanish on the dark card', () => {
    expect(contrast('#FFFFFF', '#000000')).toBeCloseTo(21);
    expect(needsOutline('#0A0A0A', '#171f33')).toBe(true); // black napkins
    expect(needsOutline('#1E3A8A', '#171f33')).toBe(true); // navy
    expect(needsOutline('#DC2626', '#171f33')).toBe(false); // red
    expect(needsOutline('nope', '#171f33')).toBe(true);
  });
});

describe('offQueueToday (owner 2026-11-09)', () => {
  it('totals the starts and keeps all four reasons in order', async () => {
    const { offQueueToday } = await import('./dashboardLogic');
    const r = offQueueToday([
      { reason: 'urgent', starts: 2, last_at: '2026-11-09T18:00:00Z' },
      { reason: 'not_ready', starts: 1, last_at: '2026-11-09T19:30:00Z' },
      { reason: 'wrong_washer', starts: 0, last_at: null },
      { reason: 'other', starts: 0, last_at: null },
    ]);
    expect(r.total).toBe(3);
    expect(r.reasons).toEqual([
      { reason: 'not_ready', starts: 1 },
      { reason: 'wrong_washer', starts: 0 },
      { reason: 'urgent', starts: 2 },
      { reason: 'other', starts: 0 },
    ]);
    expect(r.lastAt).toBe(Date.parse('2026-11-09T19:30:00Z'));
  });

  it('is empty with no rows, and ignores unknown codes and bad counts', async () => {
    const { offQueueToday } = await import('./dashboardLogic');
    const empty = offQueueToday([]);
    expect(empty.total).toBe(0);
    expect(empty.reasons).toHaveLength(4);
    expect(empty.lastAt).toBeNull();
    const odd = offQueueToday([
      { reason: 'lazy', starts: 5, last_at: '2026-11-09T18:00:00Z' },
      { reason: 'other', starts: null, last_at: null },
      { reason: 'urgent', starts: -1, last_at: null },
    ]);
    expect(odd.total).toBe(0);
    expect(odd.lastAt).toBeNull();
  });
});
