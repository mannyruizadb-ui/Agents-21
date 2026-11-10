import { describe, expect, it } from 'vitest';
import type { Category } from '../estimates/categories';
import {
  boardLoadsLeft,
  dirtyWork,
  queueLoadsLeft,
  roundedMinutes,
  roundedTime,
  wholeLoads,
  type DirtyEstimateInput,
  type DirtyGroupInput,
  type DirtyQueueInput,
  type DirtyWorkInput,
} from './dirtyWork';

const AA = 'cust-aa';

function group(id: string, over: Partial<DirtyGroupInput> = {}): DirtyGroupInput {
  return {
    id,
    name: id,
    name_i18n: {},
    color_hex: '#123456',
    wash_formula_id: `f-${id}`,
    customer_id: null,
    loads_per_basket: 3.5,
    loads_per_bin: 2,
    ...over,
  };
}

const est = (qty: number, unit: string, qty_loads: number | null): DirtyEstimateInput => ({
  qty,
  unit,
  qty_loads,
});

function q(id: string, groupId: string, over: Partial<DirtyQueueInput> = {}): DirtyQueueInput {
  return {
    id,
    wash_group_id: groupId,
    status: 'queued',
    qty: 1,
    unit: 'load',
    qty_loads: 1,
    loads_needed: 1,
    loads_remaining: 1,
    is_rewash: false,
    ...over,
  };
}

function input(over: Partial<DirtyWorkInput> = {}): DirtyWorkInput {
  return {
    groups: [],
    estimates: new Map(),
    queue: [],
    categoryOf: new Map(),
    cycleMinutesOf: () => 60,
    washers: { count: 6, capacity: 6 },
    ...over,
  };
}

describe('wholeLoads', () => {
  it('rounds up per group and ignores float noise', () => {
    expect(wholeLoads(10.5)).toBe(11);
    expect(wholeLoads(2)).toBe(2);
    expect(wholeLoads(2.0000001)).toBe(2);
    expect(wholeLoads(2.01)).toBe(3);
    expect(wholeLoads(0)).toBe(0);
    expect(wholeLoads(-1)).toBe(0);
  });
});

describe('queueLoadsLeft (AA "≈ 0 loads left" bug)', () => {
  it('a container item without a factor is unknown, not 0', () => {
    expect(
      queueLoadsLeft({
        unit: 'bin',
        qty: 3,
        qty_loads: null,
        loads_needed: null,
        loads_remaining: 0,
      }),
    ).toBeNull();
  });
  it('a null loads_needed alone makes it unknown', () => {
    expect(queueLoadsLeft({ unit: 'bin', qty: 3, loads_needed: null, loads_remaining: 0 })).toBe(
      null,
    );
  });
  it('a known count is kept, never below 0', () => {
    expect(
      queueLoadsLeft({
        unit: 'basket',
        qty: 3,
        qty_loads: 10.5,
        loads_needed: 11,
        loads_remaining: 9,
      }),
    ).toBe(9);
    expect(queueLoadsLeft({ unit: 'load', qty: 2, loads_needed: 2, loads_remaining: -1 })).toBe(0);
  });
  it('a finished known item is a real 0', () => {
    expect(
      queueLoadsLeft({ unit: 'bin', qty: 1, qty_loads: 2, loads_needed: 2, loads_remaining: 0 }),
    ).toBe(0);
  });
  it('pieces and packs have no load count', () => {
    expect(queueLoadsLeft({ unit: 'piece', qty: 40, loads_remaining: 0 })).toBeNull();
    expect(queueLoadsLeft({ unit: 'pack', qty: 4, loads_remaining: 0 })).toBeNull();
  });
  it('missing loads_remaining is unknown', () => {
    expect(queueLoadsLeft({ unit: 'load', qty: 1, loads_remaining: null })).toBeNull();
  });
});

describe('boardLoadsLeft', () => {
  it('unknown when the group has no factor for the container', () => {
    expect(boardLoadsLeft(0, 'bin', { loads_per_bin: null, loads_per_basket: 3 })).toBeNull();
    expect(boardLoadsLeft(0, 'basket', { loads_per_basket: 0 })).toBeNull();
  });
  it('known otherwise', () => {
    expect(boardLoadsLeft(9, 'basket', { loads_per_basket: 3.5 })).toBe(9);
    expect(boardLoadsLeft(2, 'load', { loads_per_basket: null })).toBe(2);
    expect(boardLoadsLeft(2, 'bin', undefined)).toBe(2);
  });
  it('null stays null; pieces have no loads', () => {
    expect(boardLoadsLeft(null, 'load', undefined)).toBeNull();
    expect(boardLoadsLeft(3, 'piece', undefined)).toBeNull();
  });
});

describe('dirtyWork: our categories', () => {
  const cats = new Map<string, Category>([
    ['black', 'mats'],
    ['charcoal', 'mats'],
    ['brito', 'mats'],
    ['white-nap', 'napkins'],
    ['black-nap', 'napkins'],
    ['sheets', 'sheets'],
    ['mops', 'mops'],
    ['cloth', 'tablecloths'],
    ['towel', 'towels_aprons'],
  ]);

  it('orders categories mats, napkins, tablecloths, towels, sheets, mops and hides empty ones', () => {
    const groups = ['mops', 'sheets', 'towel', 'cloth', 'white-nap', 'black', 'charcoal'].map(
      (id) => group(id),
    );
    const estimates = new Map([
      ['mops', est(1, 'load', 1)],
      ['sheets', est(3, 'load', 3)],
      ['towel', est(2, 'bin', 4)],
      ['cloth', est(0, 'bin', 0)], // nothing waiting: hidden
      ['white-nap', est(2.5, 'bin', 5)],
      ['black', est(3, 'basket', 10.5)],
      ['charcoal', est(2, 'basket', 7)],
    ]);
    const r = dirtyWork(input({ groups, estimates, categoryOf: cats }));
    expect(r.ours.categories.map((c) => c.category)).toEqual([
      'mats',
      'napkins',
      'towels_aprons',
      'sheets',
      'mops',
    ]);
    const mats = r.ours.categories[0];
    expect(mats?.amounts).toEqual([{ unit: 'basket', qty: 5 }]);
    // Whole loads per group, then summed: ceil(10.5) + 7 = 18 (not round(17.5)).
    expect(mats?.loads).toBe(18);
    expect(mats?.groups.map((g) => g.id)).toEqual(['black', 'charcoal']);
    expect(r.ours.loads).toBe(18 + 5 + 4 + 3 + 1);
    expect(r.ours.unknown).toBe(0);
    expect(r.estimated).toBe(7);
    expect(r.notEstimated).toBe(0);
  });

  it('never adds baskets to bins: mixed units are listed per unit', () => {
    const groups = [group('black'), group('brito'), group('charcoal')];
    const estimates = new Map([
      ['black', est(2, 'basket', 7)],
      ['brito', est(1, 'load', 1)],
      ['charcoal', est(1.5, 'bin', 3)],
    ]);
    const r = dirtyWork(input({ groups, estimates, categoryOf: cats }));
    expect(r.ours.categories[0]?.amounts).toEqual([
      { unit: 'basket', qty: 2 },
      { unit: 'bin', qty: 1.5 },
      { unit: 'load', qty: 1 },
    ]);
  });

  it('carries a mixed group second colour to its line (two-colour swatch)', () => {
    const groups = [group('mixed', { color_hex_2: '#FFFFFF' }), group('plain')];
    const estimates = new Map([
      ['mixed', est(1, 'load', 1)],
      ['plain', est(1, 'load', 1)],
    ]);
    const r = dirtyWork(input({ groups, estimates, categoryOf: cats }));
    const lines = r.ours.categories.flatMap((c) => c.groups);
    expect(lines.find((g) => g.id === 'mixed')?.color2).toBe('#FFFFFF');
    expect(lines.find((g) => g.id === 'plain')?.color2).toBeNull();
  });

  it('adds same-unit amounts exactly (quarters)', () => {
    const groups = [group('white-nap'), group('black-nap')];
    const estimates = new Map([
      ['white-nap', est(2.5, 'bin', 5)],
      ['black-nap', est(1.75, 'bin', 3.5)],
    ]);
    const r = dirtyWork(input({ groups, estimates, categoryOf: cats }));
    expect(r.ours.categories[0]?.amounts).toEqual([{ unit: 'bin', qty: 4.25 }]);
    expect(r.ours.categories[0]?.loads).toBe(5 + 4);
  });

  it('a group without a factor is unknown (never 0) and the total is a lower bound', () => {
    const groups = [group('white-nap'), group('black-nap', { loads_per_bin: null })];
    const estimates = new Map([
      ['white-nap', est(2, 'bin', 4)],
      ['black-nap', est(1, 'bin', null)],
    ]);
    const r = dirtyWork(input({ groups, estimates, categoryOf: cats }));
    const nap = r.ours.categories[0];
    expect(nap?.loads).toBe(4);
    expect(nap?.unknown).toBe(1);
    expect(nap?.groups.find((g) => g.id === 'black-nap')?.loads).toBeNull();
    expect(r.ours.unknown).toBe(1);
    expect(r.time.partial).toBe(true);
  });

  it('counts groups not estimated yet, and keeps 0 estimates as estimated', () => {
    const groups = [group('black'), group('charcoal'), group('brito')];
    const estimates = new Map([['black', est(0, 'basket', 0)]]);
    const r = dirtyWork(input({ groups, estimates, categoryOf: cats }));
    expect(r.estimated).toBe(1);
    expect(r.notEstimated).toBe(2);
    expect(r.ours.categories).toEqual([]);
    expect(r.ours.loads).toBe(0);
    expect(r.time.minutes).toBe(0);
  });

  it('unknown categories fall under other, listed last', () => {
    const groups = [group('x'), group('black')];
    const estimates = new Map([
      ['x', est(1, 'load', 1)],
      ['black', est(1, 'basket', 3.5)],
    ]);
    const r = dirtyWork(input({ groups, estimates, categoryOf: new Map([['black', 'mats']]) }));
    expect(r.ours.categories.map((c) => c.category)).toEqual(['mats', 'other']);
  });

  it('share is each category’s part of the known loads', () => {
    const groups = [group('black'), group('sheets')];
    const estimates = new Map([
      ['black', est(1, 'load', 1)],
      ['sheets', est(3, 'load', 3)],
    ]);
    const r = dirtyWork(input({ groups, estimates, categoryOf: cats }));
    expect(r.ours.categories.map((c) => c.share)).toEqual([0.25, 0.75]);
  });

  it('loads entered as fractions round up', () => {
    const r = dirtyWork(
      input({
        groups: [group('sheets')],
        estimates: new Map([['sheets', est(2.5, 'load', 2.5)]]),
        categoryOf: cats,
      }),
    );
    expect(r.ours.loads).toBe(3);
  });
});

describe('dirtyWork: AA (outside customer) from the open queue', () => {
  const groups = [
    group('aa-mats', { customer_id: AA, loads_per_bin: 4 }),
    group('aa-towels', { customer_id: AA, loads_per_bin: null }),
    group('aa-naps', { customer_id: AA, loads_per_bin: null }),
    group('black'),
  ];
  const cats = new Map<string, Category>([
    ['aa-mats', 'mats'],
    ['aa-towels', 'towels_aprons'],
    ['aa-naps', 'napkins'],
    ['black', 'mats'],
  ]);
  const queue = [
    q('1', 'aa-towels', {
      unit: 'bin',
      qty: 3,
      qty_loads: null,
      loads_needed: null,
      loads_remaining: 0,
    }),
    q('2', 'aa-mats', { unit: 'bin', qty: 2, qty_loads: 8, loads_needed: 8, loads_remaining: 8 }),
    q('3', 'aa-naps', {
      unit: 'bin',
      qty: 1.5,
      qty_loads: null,
      loads_needed: null,
      loads_remaining: 0,
    }),
    q('4', 'black', { unit: 'basket', qty: 3, qty_loads: 10.5, loads_remaining: 9 }),
    q('5', 'aa-mats', { status: 'done', loads_remaining: 0 }),
    q('6', 'aa-mats', { status: 'cancelled', loads_remaining: 4 }),
  ];

  it('is separate from our estimates and shows "8+" (never 0)', () => {
    const r = dirtyWork(
      input({
        groups,
        estimates: new Map([['black', est(3, 'basket', 10.5)]]),
        queue,
        categoryOf: cats,
      }),
    );
    expect(r.ours.loads).toBe(11);
    expect(r.customers).toHaveLength(1);
    const aa = r.customers[0];
    expect(aa?.customerId).toBe(AA);
    expect(aa?.items).toBe(3);
    expect(aa?.loads).toBe(8);
    expect(aa?.unknown).toBe(2);
    expect(aa?.categories.map((c) => c.category)).toEqual(['mats', 'napkins', 'towels_aprons']);
    expect(aa?.categories[2]?.amounts).toEqual([{ unit: 'bin', qty: 3 }]);
    expect(aa?.categories[2]?.groups[0]?.loads).toBeNull();
  });

  it('adds several deliveries of one group; partly unknown is flagged', () => {
    const r = dirtyWork(
      input({
        groups,
        queue: [
          q('a', 'aa-mats', {
            unit: 'bin',
            qty: 1,
            qty_loads: 4,
            loads_needed: 4,
            loads_remaining: 4,
          }),
          q('b', 'aa-mats', {
            unit: 'bin',
            qty: 0.5,
            qty_loads: 2,
            loads_needed: 2,
            loads_remaining: 2,
          }),
          q('c', 'aa-mats', {
            unit: 'basket',
            qty: 1,
            qty_loads: null,
            loads_needed: null,
            loads_remaining: 0,
          }),
        ],
        categoryOf: cats,
      }),
    );
    const line = r.customers[0]?.categories[0]?.groups[0];
    expect(line?.amounts).toEqual([
      { unit: 'basket', qty: 1 },
      { unit: 'bin', qty: 1.5 },
    ]);
    expect(line?.loads).toBe(6);
    expect(line?.partlyUnknown).toBe(true);
    expect(r.customers[0]?.unknown).toBe(1);
  });

  it('a customer with nothing in the queue still has an (empty) section', () => {
    const r = dirtyWork(input({ groups, queue: [], categoryOf: cats }));
    expect(r.customers).toEqual([
      { customerId: AA, items: 0, categories: [], loads: 0, unknown: 0 },
    ]);
  });

  it('uses customerOf when the group row has no customer_id', () => {
    const r = dirtyWork(
      input({
        groups: [group('aa-mats')],
        queue: [q('a', 'aa-mats')],
        customerOf: (id) => (id === 'aa-mats' ? AA : null),
      }),
    );
    expect(r.customers[0]?.loads).toBe(1);
    expect(r.ours.categories).toEqual([]);
  });

  it('works without a queue (not loaded yet)', () => {
    const r = dirtyWork(input({ groups: [group('black')], queue: undefined }));
    expect(r.rewash).toEqual({ items: 0, loads: 0, unknown: 0 });
  });
});

describe('dirtyWork: rewash', () => {
  it('counts our open rewash items from the queue', () => {
    const r = dirtyWork(
      input({
        groups: [group('black'), group('aa', { customer_id: AA })],
        queue: [
          q('1', 'black', { is_rewash: true, loads_remaining: 1 }),
          q('2', 'black', { is_rewash: false, loads_remaining: 3 }),
          q('3', 'black', {
            is_rewash: true,
            unit: 'bin',
            qty: 1,
            qty_loads: null,
            loads_needed: null,
            loads_remaining: 0,
          }),
          q('4', 'aa', { is_rewash: true, loads_remaining: 2 }),
        ],
      }),
    );
    expect(r.rewash).toEqual({ items: 2, loads: 1, unknown: 1 });
  });
});

describe('dirtyWork: time', () => {
  const cats = new Map<string, Category>();
  const minutes: Record<string, number | null> = {
    'f-sheets': 25,
    'f-black': 45,
    'f-mops': 80,
    'f-none': null,
  };
  const cycleMinutesOf = (id: string | null) => (id ? (minutes[id] ?? null) : null);

  it('is washer-minutes ÷ capacity on the washers up now', () => {
    const r = dirtyWork(
      input({
        groups: [group('sheets'), group('black')],
        estimates: new Map([
          ['sheets', est(12, 'load', 12)],
          ['black', est(2, 'load', 2)],
        ]),
        categoryOf: cats,
        cycleMinutesOf,
        washers: { count: 6, capacity: 6 },
      }),
    );
    // (12 × 25 + 2 × 45) / 6 = 65 min
    expect(r.time.minutes).toBe(65);
    expect(r.time.washers).toBe(6);
    expect(r.time.reason).toBeNull();
  });

  it('is never less than the longest single cycle waiting', () => {
    const r = dirtyWork(
      input({
        groups: [group('mops'), group('sheets')],
        estimates: new Map([
          ['mops', est(1, 'load', 1)],
          ['sheets', est(1, 'load', 1)],
        ]),
        categoryOf: cats,
        cycleMinutesOf,
        washers: { count: 6, capacity: 6 },
      }),
    );
    // (80 + 25) / 6 = 17.5 → but one mop load alone takes 80 min.
    expect(r.time.minutes).toBe(80);
  });

  it('uses whole loads (not decimals) and the load-factor capacity', () => {
    const r = dirtyWork(
      input({
        groups: [group('black')],
        estimates: new Map([['black', est(3, 'basket', 10.5)]]),
        categoryOf: cats,
        cycleMinutesOf,
        washers: { count: 5, capacity: 5.19 },
      }),
    );
    expect(r.time.minutes).toBeCloseTo((11 * 45) / 5.19, 6);
  });

  it('includes the customer’s known loads', () => {
    const r = dirtyWork(
      input({
        groups: [group('black', { customer_id: AA })],
        queue: [q('1', 'black', { loads_remaining: 6, loads_needed: 6, qty: 6 })],
        categoryOf: cats,
        cycleMinutesOf,
        washers: { count: 3, capacity: 3 },
      }),
    );
    expect(r.time.minutes).toBe(90);
  });

  it('says why there is no time: no working washer', () => {
    const r = dirtyWork(
      input({
        groups: [group('sheets')],
        estimates: new Map([['sheets', est(1, 'load', 1)]]),
        categoryOf: cats,
        cycleMinutesOf,
        washers: { count: 0, capacity: 0 },
      }),
    );
    expect(r.time).toMatchObject({ minutes: null, reason: 'noWashers', washers: 0 });
  });

  it('says why there is no time: no cycle minutes set', () => {
    const r = dirtyWork(
      input({
        groups: [group('none', { wash_formula_id: 'f-none' })],
        estimates: new Map([['none', est(2, 'load', 2)]]),
        categoryOf: cats,
        cycleMinutesOf,
      }),
    );
    expect(r.time).toMatchObject({ minutes: null, reason: 'noTime', noTime: 1 });
  });

  it('counts groups without a cycle time apart and still times the rest', () => {
    const r = dirtyWork(
      input({
        groups: [group('none', { wash_formula_id: 'f-none' }), group('sheets')],
        estimates: new Map([
          ['none', est(2, 'load', 2)],
          ['sheets', est(6, 'load', 6)],
        ]),
        categoryOf: cats,
        cycleMinutesOf,
        washers: { count: 6, capacity: 6 },
      }),
    );
    expect(r.time.minutes).toBe(25);
    expect(r.time.noTime).toBe(1);
  });

  it('a pile with nothing waiting is 0 minutes, even with no washers', () => {
    const r = dirtyWork(input({ washers: { count: 0, capacity: 0 } }));
    expect(r.time.minutes).toBe(0);
    expect(r.time.reason).toBeNull();
  });

  it('a breakdown changes the hours, not the pile', () => {
    const base = {
      groups: [group('sheets')],
      estimates: new Map([['sheets', est(12, 'load', 12)]]),
      categoryOf: cats,
      cycleMinutesOf,
    };
    const six = dirtyWork(input({ ...base, washers: { count: 6, capacity: 6 } }));
    const five = dirtyWork(input({ ...base, washers: { count: 5, capacity: 5 } }));
    expect(six.ours.loads).toBe(five.ours.loads);
    expect(five.time.minutes).toBeGreaterThan(six.time.minutes ?? 0);
  });
});

describe('roundedTime', () => {
  it('rounds to 5 minutes, at least 5 when above 0', () => {
    expect(roundedTime(0)).toEqual({ h: 0, m: 0 });
    expect(roundedTime(1)).toEqual({ h: 0, m: 5 });
    expect(roundedTime(62)).toEqual({ h: 1, m: 0 });
    expect(roundedTime(63)).toEqual({ h: 1, m: 5 });
    expect(roundedTime(80)).toEqual({ h: 1, m: 20 });
    expect(roundedMinutes(83)).toBe(85);
  });
});

describe('dirtyWork: loads left (owner 2026-11-10, one rule)', () => {
  const base = (estimates: Map<string, DirtyEstimateInput>) =>
    dirtyWork({
      groups: [
        {
          id: 'g1',
          name: 'Black mats',
          name_i18n: null,
          color_hex: null,
          wash_formula_id: null,
          customer_id: null,
          loads_per_basket: 0.5,
        },
      ],
      estimates,
      categoryOf: new Map([['g1', 'mats']]),
      cycleMinutesOf: () => 45,
      washers: { count: 6, capacity: 6 },
    });
  it('uses the database loads_left: estimate minus starts since it was entered', () => {
    const w = base(new Map([['g1', { qty: 12, unit: 'basket', qty_loads: 6, loads_left: 2 }]]));
    expect(w.ours.loads).toBe(2);
    expect(w.ours.categories[0]?.amounts).toEqual([{ unit: 'load', qty: 2 }]);
  });
  it('keeps the typed amount while nothing has been washed', () => {
    const w = base(new Map([['g1', { qty: 12, unit: 'basket', qty_loads: 6, loads_left: 6 }]]));
    expect(w.ours.categories[0]?.amounts).toEqual([{ unit: 'basket', qty: 12 }]);
  });
  it('a group washed out is not waiting any more', () => {
    const w = base(new Map([['g1', { qty: 12, unit: 'basket', qty_loads: 6, loads_left: 0 }]]));
    expect(w.ours.categories).toEqual([]);
    expect(w.estimated).toBe(1);
  });
  it('without loads_left (typed, not saved) it is the estimate itself', () => {
    const w = base(new Map([['g1', { qty: 12, unit: 'basket', qty_loads: 6 }]]));
    expect(w.ours.loads).toBe(6);
  });
});
