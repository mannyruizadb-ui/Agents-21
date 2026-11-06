import { describe, expect, it } from 'vitest';
import {
  addDays,
  localRouteName,
  loadOutRows,
  nextLoadDate,
  nextTruck,
  parseQty,
  plantLocal,
  previousLoadDate,
  routesForDate,
  zonedToEpoch,
} from './loadOutLogic';

const NY = 'America/New_York';
const route = (id: string, time: string, days: number[], active = true) => ({
  id,
  name: `Route ${id}`,
  load_time: time,
  days_of_week: days,
  active,
});
// ADB routes (owner 2026-11-06)
const ROUTES = [
  route('21', '03:30:00', [1, 2, 4, 5]),
  route('11', '04:30:00', [1, 4]),
  route('5', '04:30:00', [2, 5]),
  route('2', '05:00:00', [1, 2, 3, 4, 5]),
  route('4', '05:30:00', [1, 2, 4, 5]),
  route('old', '06:00:00', [1, 2, 3, 4, 5], false),
];

describe('plant time', () => {
  it('reads the plant-local date and time', () => {
    expect(plantLocal(Date.parse('2026-11-06T04:30:00Z'), NY)).toEqual({
      date: '2026-11-05',
      time: '23:30',
    });
  });
  it('the next loading morning is today before noon, else tomorrow', () => {
    expect(nextLoadDate(Date.parse('2026-11-06T13:00:00Z'), NY)).toBe('2026-11-06'); // 08:00 local
    expect(nextLoadDate(Date.parse('2026-11-06T18:00:00Z'), NY)).toBe('2026-11-07'); // 13:00 local
  });
  it('converts a plant-local truck time to an instant, across DST', () => {
    expect(new Date(zonedToEpoch('2026-11-06', '03:30:00', NY)).toISOString()).toBe(
      '2026-11-06T08:30:00.000Z',
    );
    expect(new Date(zonedToEpoch('2026-07-06', '03:30', NY)).toISOString()).toBe(
      '2026-07-06T07:30:00.000Z',
    );
    expect(addDays('2026-11-30', 1)).toBe('2026-12-01');
  });
});

describe('routes', () => {
  it('only active routes that run that weekday, by load time', () => {
    expect(routesForDate(ROUTES, '2026-11-09').map((r) => r.id)).toEqual(['21', '11', '2', '4']); // Monday
    expect(routesForDate(ROUTES, '2026-11-11').map((r) => r.id)).toEqual(['2']); // Wednesday
    expect(routesForDate(ROUTES, '2026-11-08')).toEqual([]); // Sunday
  });
  it('"same as yesterday" skips days without routes (Monday copies Friday)', () => {
    expect(previousLoadDate(ROUTES, '2026-11-09')).toBe('2026-11-06');
    expect(previousLoadDate(ROUTES, '2026-11-10')).toBe('2026-11-09');
    expect(previousLoadDate([], '2026-11-10')).toBeNull();
  });
  it('counts down to the next truck not loaded, negative when late', () => {
    const board = [
      { route_id: 'a', name: 'Route 21', load_time: '03:30:00', loaded: true },
      { route_id: 'b', name: 'Route 2', load_time: '05:00:00', loaded: false },
      { route_id: 'c', name: 'Route 4', load_time: '05:30:00', loaded: false },
    ];
    const now = Date.parse('2026-11-06T09:40:00Z'); // 04:40 local
    expect(nextTruck(board, '2026-11-06', now, NY)).toMatchObject({
      route: { route_id: 'b' },
      minutes: 20,
    });
    expect(nextTruck(board, '2026-11-06', Date.parse('2026-11-06T10:10:00Z'), NY)?.minutes).toBe(
      -10,
    );
    expect(
      nextTruck(
        board.map((r) => ({ ...r, loaded: true })),
        '2026-11-06',
        now,
        NY,
      ),
    ).toBeNull();
  });
});

describe('rows and quantities', () => {
  const items = [
    { id: 's1', name: 'Sheet – regular', sort_order: 580, active: true },
    { id: 'b1', name: 'Butcher coat M', sort_order: 260, active: true },
    { id: 'x', name: 'Chef coat', sort_order: 250, active: true },
    { id: 'y', name: 'Kitchen towel', sort_order: 100, active: true },
    { id: 'z', name: 'Soil bags', sort_order: 900, active: true },
    { id: 'off', name: 'Sheet – retired', sort_order: 600, active: false },
  ];
  it("shows the owner's default items, recent and added ones, in item order", () => {
    expect(loadOutRows(items, new Set(), new Set()).map((i) => i.id)).toEqual(['b1', 's1', 'z']);
    expect(loadOutRows(items, new Set(['x']), new Set(['y'])).map((i) => i.id)).toEqual([
      'y',
      'x',
      'b1',
      's1',
      'z',
    ]);
  });
  it('parses whole quantities 0–100,000', () => {
    expect(parseQty('12')).toBe(12);
    expect(parseQty('')).toBe(0);
    for (const bad of ['1.5', '-1', 'abc', '100001']) expect(parseQty(bad)).toBeNull();
  });
});

describe('localRouteName', () => {
  it('shows seeded route names in Spanish and keeps others as entered', () => {
    expect(localRouteName('Route 21', 'es')).toBe('Ruta 21');
    expect(localRouteName('route 4', 'es-US')).toBe('Ruta 4');
    expect(localRouteName('Route 21', 'en')).toBe('Route 21');
    expect(localRouteName('Hialeah run', 'es')).toBe('Hialeah run');
    expect(localRouteName('Route 21 extra', 'es')).toBe('Route 21 extra');
  });
});
