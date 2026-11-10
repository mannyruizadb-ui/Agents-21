import { describe, expect, it } from 'vitest';
import { memoryStore } from '../../lib/scopedStore';
import {
  addWorking,
  amountKey,
  binAmount,
  bigNumberWarnings,
  buildReview,
  finishGroupOf,
  isDoubleTap,
  isFinishingItem,
  isSheetsDoneItem,
  itemTotal,
  loadSheetsCount,
  loadWorking,
  looseAmount,
  MAX_WORKING,
  normalizeWorking,
  packsAmount,
  pacePerHour,
  parseCount,
  previewPieces,
  removeWorking,
  saveSheetsCount,
  saveWorking,
  SINGLE_ENTRY_CONFIRM,
  type FinishItem,
  type LogLine,
} from './finishedLogic';

const item = (over: Partial<FinishItem> = {}): FinishItem => ({
  id: 'i1',
  name: 'Sheet – regular',
  name_i18n: {},
  category: 'linen',
  count_mode: 'pack',
  pack_size: 10,
  bin_size: 500,
  color_hex: '#FFFFFF',
  sort_order: 1,
  active: true,
  washed: true,
  ...over,
});

const line = (over: Partial<LogLine> = {}): LogLine => ({
  key: Math.random().toString(),
  itemTypeId: 'i1',
  packs: 0,
  loose: 0,
  pieces: 0,
  occurredAt: '2026-11-10T15:00:00Z',
  id: 'x',
  clientId: 'c',
  pending: false,
  ...over,
});

describe('which items finishing counts', () => {
  it('keeps washed active linens, towels and apparel; never mats, mops or soil bags', () => {
    expect(isFinishingItem(item())).toBe(true);
    expect(isFinishingItem(item({ category: 'towel' }))).toBe(true);
    expect(isFinishingItem(item({ category: 'apparel' }))).toBe(true);
    expect(isFinishingItem(item({ category: 'mat' }))).toBe(false);
    expect(isFinishingItem(item({ category: 'mop' }))).toBe(false);
    expect(isFinishingItem(item({ category: 'other', washed: false }))).toBe(false);
    expect(isFinishingItem(item({ active: false }))).toBe(false);
  });
  it('groups by category and linen name', () => {
    expect(finishGroupOf(item({ name: 'Napkin – Navy Blue' }))).toBe('napkins');
    expect(finishGroupOf(item({ name: 'Tablecloth 52×52 white' }))).toBe('tablecloths');
    expect(finishGroupOf(item({ name: 'Sheet – old' }))).toBe('sheets');
    expect(finishGroupOf(item({ name: 'Kitchen towel', category: 'towel' }))).toBe('towels');
    expect(finishGroupOf(item({ name: 'Chef coat', category: 'apparel' }))).toBe('apparel');
    expect(finishGroupOf(item({ name: 'Pillowcase' }))).toBe('other');
  });
  it('Sheets done… only for sheets with packs and no bin size (Sheet – old)', () => {
    expect(isSheetsDoneItem(item({ name: 'Sheet – old', bin_size: null }))).toBe(true);
    expect(isSheetsDoneItem(item())).toBe(false);
    expect(isSheetsDoneItem(item({ name: 'Napkin – Red', bin_size: null }))).toBe(false);
    expect(
      isSheetsDoneItem(
        item({ name: 'Sheet – old', bin_size: null, count_mode: 'unit', pack_size: null }),
      ),
    ).toBe(false);
  });
  it('a Sheets done count goes in as loose pieces (one count, no packs)', () => {
    const old = item({ name: 'Sheet – old', bin_size: null });
    expect(looseAmount(old, 500)).toEqual({ packs: 0, loose: 500, packSize: 10 });
    expect(previewPieces(looseAmount(old, 500))).toBe(500);
  });
});

describe('amounts and the pack preview text', () => {
  it('bin goes in as loose pieces', () => {
    expect(binAmount(item())).toEqual({ packs: 0, loose: 500, packSize: 10 });
    expect(binAmount(item({ bin_size: null }))).toBeNull();
    expect(previewPieces(binAmount(item()) ?? { packs: 0, loose: 0, packSize: null })).toBe(500);
  });
  it('packs × pack size + loose', () => {
    const napkin = item({ pack_size: 100, bin_size: null });
    expect(previewPieces(packsAmount(napkin, 5))).toBe(500);
    expect(previewPieces(looseAmount(napkin, 40))).toBe(40);
    expect(previewPieces({ packs: 73, loose: 40, packSize: 100 })).toBe(7340);
    expect(looseAmount(item({ count_mode: 'unit', pack_size: null }), 3).packSize).toBeNull();
  });
  it('wording key: "73 packs + 40 = 7,340", "5 packs = 500", "40 pieces"', () => {
    expect(amountKey(73, 40, 7340)).toEqual({
      key: 'finished.amount.packsLoose',
      values: { packs: 73, loose: 40, pieces: 7340, count: 73 },
    });
    expect(amountKey(5, 0, 500).key).toBe('finished.amount.packs');
    expect(amountKey(0, 40, 40)).toEqual({
      key: 'finished.amount.pieces',
      values: { packs: 0, loose: 40, pieces: 40, count: 40 },
    });
  });
  it('parses typed counts', () => {
    expect(parseCount('500')).toBe(500);
    expect(parseCount(' 1,200 ')).toBe(1200);
    expect(parseCount('0')).toBeNull();
    expect(parseCount('-3')).toBeNull();
    expect(parseCount('abc')).toBeNull();
    expect(parseCount('100001')).toBeNull();
  });
});

describe('double-tap guard', () => {
  const last = { itemId: 'i1', pieces: 500, at: 1_000 };
  it('same item and amount within 5 s asks', () => {
    expect(isDoubleTap(last, 'i1', 500, 4_000)).toBe(true);
  });
  it('after 5 s, another item or another amount saves', () => {
    expect(isDoubleTap(last, 'i1', 500, 6_000)).toBe(false);
    expect(isDoubleTap(last, 'i2', 500, 2_000)).toBe(false);
    expect(isDoubleTap(last, 'i1', 100, 2_000)).toBe(false);
    expect(isDoubleTap(null, 'i1', 500, 2_000)).toBe(false);
  });
});

describe('big-number check', () => {
  it('over the stock owned: from the server answer, never a number on the client', () => {
    expect(bigNumberWarnings(2000, true)).toEqual([{ kind: 'stock' }]);
    expect(bigNumberWarnings(500, false)).toEqual([]);
  });
  it('stock unknown (offline, failed): the stock check is skipped, saving is not blocked', () => {
    expect(bigNumberWarnings(500, null)).toEqual([]);
  });
  it('a single entry over 5,000 is checked on the client, even offline', () => {
    expect(bigNumberWarnings(SINGLE_ENTRY_CONFIRM, null)).toEqual([]);
    expect(bigNumberWarnings(6000, null)).toEqual([{ kind: 'single', pieces: 6000 }]);
    expect(bigNumberWarnings(6000, true).map((w) => w.kind)).toEqual(['stock', 'single']);
  });
});

describe('pace and review', () => {
  it('pieces per hour between first and last line', () => {
    expect(pacePerHour(['2026-11-10T14:00:00Z', '2026-11-10T16:00:00Z'], 3000)).toBe(1500);
    expect(pacePerHour(['2026-11-10T14:00:00Z'], 3000)).toBeNull();
    expect(pacePerHour(['2026-11-10T14:00:00Z', '2026-11-10T14:05:00Z'], 3000)).toBeNull();
  });
  it('per item totals in item order, never per person', () => {
    const lines = [
      line({ itemTypeId: 'b', packs: 70, pieces: 7000, occurredAt: '2026-11-10T14:00:00Z' }),
      line({
        itemTypeId: 'b',
        packs: 3,
        loose: 40,
        pieces: 340,
        occurredAt: '2026-11-10T16:00:00Z',
      }),
      line({ itemTypeId: 'a', loose: 500, pieces: 500, occurredAt: '2026-11-10T15:00:00Z' }),
    ];
    const rows = buildReview(lines, ['a', 'b', 'c']);
    expect(rows.map((r) => r.itemTypeId)).toEqual(['a', 'b']);
    expect(rows[1]).toMatchObject({
      packs: 73,
      loose: 40,
      pieces: 7340,
      lines: 2,
      first: '2026-11-10T14:00:00Z',
      last: '2026-11-10T16:00:00Z',
      pace: 3670,
    });
    expect(Object.keys(rows[0] ?? {})).not.toContain('enteredBy');
    expect(itemTotal(lines, 'b')).toBe(7340);
  });
});

describe('working-on list (per user per device)', () => {
  it('pins, selects, caps at 6 and removes', () => {
    let p = normalizeWorking(null);
    expect(p).toEqual({ items: [], selected: null });
    for (const id of ['1', '2', '3', '4', '5', '6', '7']) p = addWorking(p, id);
    expect(p.items).toHaveLength(MAX_WORKING);
    expect(p.items[0]).toBe('2');
    expect(p.selected).toBe('7');
    p = removeWorking(p, '7');
    expect(p.selected).toBe('2');
    expect(addWorking(p, '3').items).toEqual(p.items);
  });
  it('drops unknown items and survives junk', () => {
    expect(normalizeWorking({ items: ['a', 'x', 'a', 3], selected: 'x' }, new Set(['a']))).toEqual({
      items: ['a'],
      selected: 'a',
    });
    const store = memoryStore();
    store.setItem('finished.working.v1', '{bad json');
    expect(loadWorking(store).items).toEqual([]);
    saveWorking(store, { items: ['a', 'b'], selected: 'b' });
    expect(loadWorking(store)).toEqual({ items: ['a', 'b'], selected: 'b' });
  });
  it('remembers the last old-sheets count per item', () => {
    const store = memoryStore();
    expect(loadSheetsCount(store, 'old')).toBeNull();
    saveSheetsCount(store, 'old', 500);
    saveSheetsCount(store, 'other', 10);
    expect(loadSheetsCount(store, 'old')).toBe(500);
  });
});
