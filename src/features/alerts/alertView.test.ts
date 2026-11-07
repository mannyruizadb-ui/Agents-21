import { describe, expect, it } from 'vitest';
import { describeAlert, minutesAgo, splitAlerts, wallTimeDate, type AlertRow } from './alertView';

const M = '8459e714-a8dc-4ea6-a205-ea31b70119ee';
const row = (
  kind: string,
  payload: unknown,
  still = true,
  at = '2026-11-06T10:00:00Z',
): AlertRow => ({
  alert_id: `${kind}-${at}`,
  kind,
  created_at: at,
  payload,
  still_current: still,
});

describe('describeAlert', () => {
  it('machine down links to the machine and is open while still down', () => {
    const v = describeAlert(
      row('machine_down', { machine_id: M, machine_name: 'Washer 4', reason_code: 'water_pump' }),
    );
    expect(v).toMatchObject({
      kind: 'machine_down',
      tone: 'danger',
      to: `/control/machines?machine=${M}`,
      open: true,
      resolved: false,
      machineName: 'Washer 4',
      reasonCode: 'water_pump',
    });
    expect(describeAlert(row('machine_down', { machine_id: M }, false))).toMatchObject({
      open: false,
      resolved: true,
    });
  });

  it('washer idle goes to the board; tasks to tasks; routes to load-out', () => {
    expect(describeAlert(row('washer_idle', { machine_id: M }))?.to).toBe('/control/washers');
    expect(
      describeAlert(row('task_assigned', { task_id: 't', body: 'Check trucks' })),
    ).toMatchObject({ to: '/control/tasks', open: true, taskText: 'Check trucks' });
    expect(describeAlert(row('task_done', { task_id: 't' }, false))).toMatchObject({
      open: false,
      resolved: false,
    });
    expect(
      describeAlert(row('route_loaded', { route_id: 'r', route_name: 'Route 21' })),
    ).toMatchObject({
      to: '/control/load-out',
      open: false,
      resolved: false,
      routeName: 'Route 21',
    });
    expect(describeAlert(row('route_loaded', { route_id: 'r' }, false))?.resolved).toBe(true);
  });

  it('drops unknown kinds and unusable payloads', () => {
    expect(describeAlert(row('something_new', { machine_id: M }))).toBeNull();
    expect(describeAlert(row('machine_down', null))).toBeNull();
    expect(describeAlert(row('machine_down', ['x']))).toBeNull();
    expect(describeAlert(row('machine_down', { machine_id: '../x?y' }))).toBeNull();
    expect(describeAlert(row('task_done', {}))).toBeNull();
  });

  it('cleans control characters from stored text', () => {
    expect(
      describeAlert(row('task_assigned', { task_id: 't', body: 'a\u0007\n b' }))?.taskText,
    ).toBe('a b');
  });
});

describe('owner information alerts', () => {
  it('customer delivery: lines, never open, voided = resolved, + N more', () => {
    const lines = [1, 2, 3, 4, 5].map((i) => ({
      wash_group_id: `g${i}`,
      wash_group_name: `Group ${i}`,
      wash_group_name_i18n: { es: `Grupo ${i}` },
      bins: i === 1 ? '0.5' : i,
      loads: null,
    }));
    const v = describeAlert(
      row('customer_delivery', {
        delivery_id: 'd',
        customer_name: 'AA Linen',
        customer_name_i18n: {},
        lines,
        voided: false,
      }),
    );
    expect(v).toMatchObject({
      kind: 'customer_delivery',
      tone: 'info',
      to: '/control/deliveries',
      open: false,
      resolved: false,
      customerName: 'AA Linen',
      moreLines: 1,
    });
    expect(v?.deliveryLines).toHaveLength(4);
    expect(v?.deliveryLines?.[0]).toEqual({
      name: 'Group 1',
      nameI18n: { es: 'Grupo 1' },
      bins: 0.5,
    });
    expect(
      describeAlert(row('customer_delivery', { delivery_id: 'd', voided: true })),
    ).toMatchObject({ resolved: true, deliveryLines: [], moreLines: 0 });
    expect(describeAlert(row('customer_delivery', { lines }))).toBeNull();
  });

  it('estimates entered: the group count', () => {
    expect(
      describeAlert(row('estimate_entered', { first_estimate_id: 'e', count: 3, estimates: [] })),
    ).toMatchObject({ kind: 'estimate_entered', to: '/control/estimates', open: false, count: 3 });
    expect(
      describeAlert(row('estimate_entered', { first_estimate_id: 'e', estimates: [{}, {}] }))
        ?.count,
    ).toBe(2);
  });

  it('rewash added: group, amount and a known unit only', () => {
    expect(
      describeAlert(
        row('rewash_added', {
          queue_item_id: 'q',
          wash_group_name: 'Napkins',
          qty: 0.5,
          unit: 'bin',
        }),
      ),
    ).toMatchObject({
      kind: 'rewash_added',
      to: '/control/queue',
      open: false,
      group: { name: 'Napkins' },
      qty: 0.5,
      unit: 'bin',
    });
    expect(describeAlert(row('rewash_added', { queue_item_id: 'q', unit: 'x' }))).toMatchObject({
      group: null,
      unit: null,
      qty: null,
    });
  });

  it('off-queue start: washer, group, what the queue had; undone = resolved', () => {
    expect(
      describeAlert(
        row('off_queue_start', {
          cycle_id: 'c',
          machine_name: 'Washer 3',
          wash_group_name: 'Napkins',
          expected_wash_group_name: 'Tablecloths',
          off_queue: false,
          voided: false,
        }),
      ),
    ).toMatchObject({
      kind: 'off_queue_start',
      to: '/control/washers',
      open: false,
      resolved: false,
      machineName: 'Washer 3',
      group: { name: 'Napkins' },
      expectedGroup: { name: 'Tablecloths' },
    });
    expect(
      describeAlert(row('off_queue_start', { cycle_id: 'c', voided: true, off_queue: true })),
    ).toMatchObject({ resolved: true, expectedGroup: null });
  });

  it('owner information alerts go under Earlier', () => {
    const s = splitAlerts([
      row('customer_delivery', { delivery_id: 'd' }),
      row('rewash_added', { queue_item_id: 'q' }),
    ]);
    expect(s.open).toEqual([]);
    expect(s.earlier).toHaveLength(2);
  });
});

describe('splitAlerts', () => {
  it('puts open alerts first, newest first, and skips unusable rows', () => {
    const s = splitAlerts([
      row('task_done', { task_id: 'a' }, false, '2026-11-06T09:00:00Z'),
      row('machine_down', { machine_id: M }, true, '2026-11-06T08:00:00Z'),
      row('washer_idle', { machine_id: M }, true, '2026-11-06T11:00:00Z'),
      row('bogus', {}, true, '2026-11-06T12:00:00Z'),
    ]);
    expect(s.open.map((v) => v.kind)).toEqual(['washer_idle', 'machine_down']);
    expect(s.earlier.map((v) => v.kind)).toEqual(['task_done']);
  });
});

describe('time helpers', () => {
  it('minutesAgo floors and never goes negative', () => {
    const now = Date.parse('2026-11-06T10:05:30Z');
    expect(minutesAgo('2026-11-06T10:00:00Z', now)).toBe(5);
    expect(minutesAgo('2026-11-06T10:10:00Z', now)).toBe(0);
    expect(minutesAgo('nope', now)).toBeNull();
  });
  it('wallTimeDate reads HH:MM(:SS)', () => {
    expect(wallTimeDate('03:30')?.getUTCHours()).toBe(3);
    expect(wallTimeDate('03:30:00')?.getUTCMinutes()).toBe(30);
    expect(wallTimeDate('25:00')).toBeNull();
    expect(wallTimeDate(null)).toBeNull();
  });
});
