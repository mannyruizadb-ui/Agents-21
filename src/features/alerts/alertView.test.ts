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
