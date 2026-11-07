import { describe, expect, it } from 'vitest';
import {
  alertLevelFor,
  alertRowsFor,
  defaultAlertLevel,
  withAlertLevel,
  type AlertMembership,
} from './alertRecipients';

const plant = { id: 'p1', org_id: 'o1' };
const m = (over: Partial<AlertMembership>): AlertMembership => ({
  id: 'm1',
  user_id: 'u1',
  org_id: 'o1',
  plant_id: 'p1',
  role: 'manager',
  notify_machine_down: false,
  notify_washer_idle: true,
  can_enter_load_out: false,
  ...over,
});

describe('alertRowsFor', () => {
  it("keeps the person's plant and org-wide memberships of this org only", () => {
    const rows = alertRowsFor(
      [
        m({ id: 'a' }),
        m({ id: 'b', plant_id: null, role: 'owner', notify_machine_down: true }),
        m({ id: 'c', plant_id: 'p2' }),
        m({ id: 'd', org_id: 'o2' }),
        m({ id: 'e', user_id: 'u2' }),
      ],
      'u1',
      plant,
      'u1',
    );
    expect(rows.map((r) => r.membershipId)).toEqual(['a', 'b']);
    expect(rows[1]).toMatchObject({ orgWide: true, on: true, canEnable: true });
  });
  it('only owner and manager memberships can be turned on', () => {
    const rows = alertRowsFor(
      [m({ id: 'l', role: 'lead' }), m({ id: 'v', role: 'viewer' }), m({ id: 'o', role: 'owner' })],
      'u1',
      plant,
      'u1',
    );
    expect(rows.map((r) => [r.role, r.canEnable])).toEqual([
      ['lead', false],
      ['viewer', false],
      ['owner', true],
    ]);
  });
});

describe('owner alert levels', () => {
  it('defaults: deliveries buzz, the rest are quiet', () => {
    expect(defaultAlertLevel('customer_delivery')).toBe('push');
    expect(defaultAlertLevel('estimate_entered')).toBe('quiet');
    expect(defaultAlertLevel('account_locked')).toBe('push');
    expect(alertLevelFor(null, 'customer_delivery')).toBe('push');
    expect(alertLevelFor({ rewash_added: 'loud' }, 'rewash_added')).toBe('quiet');
  });
  it('reads a stored level and changes one kind', () => {
    expect(alertLevelFor({ estimate_entered: 'off' }, 'estimate_entered')).toBe('off');
    expect(withAlertLevel({ rewash_added: 'push' }, 'customer_delivery', 'off')).toEqual({
      customer_delivery: 'off',
      estimate_entered: 'quiet',
      rewash_added: 'push',
      account_locked: 'push',
    });
  });
  it('every membership row carries its levels', () => {
    const rows = alertRowsFor(
      [m({ role: 'owner', alert_levels: { account_locked: 'quiet' } })],
      'u1',
      plant,
      'u1',
    );
    expect(rows[0]?.levels).toEqual({
      customer_delivery: 'push',
      estimate_entered: 'quiet',
      rewash_added: 'quiet',
      account_locked: 'quiet',
    });
  });
});

describe('self-only owner settings (2026-11-07)', () => {
  const list = [
    m({ id: 'me', user_id: 'owner1', role: 'owner' }),
    m({ id: 'dad', user_id: 'owner2', role: 'owner', plant_id: null }),
    m({ id: 'mgr', user_id: 'mgr1', role: 'manager' }),
  ];
  it("only the signed-in owner's own owner rows get levels and the idle switch", () => {
    expect(alertRowsFor(list, 'owner1', plant, 'owner1')[0]).toMatchObject({
      ownSettings: true,
      canToggleMachineDown: true,
    });
    expect(alertRowsFor(list, 'owner2', plant, 'owner1')[0]).toMatchObject({
      ownSettings: false,
      canToggleMachineDown: false,
    });
  });
  it("managers' machine-down switch stays with the owner; no owner settings", () => {
    expect(alertRowsFor(list, 'mgr1', plant, 'owner1')[0]).toMatchObject({
      ownSettings: false,
      canToggleMachineDown: true,
    });
  });
});
