import { describe, expect, it } from 'vitest';
import { alertRowsFor, type AlertMembership } from './alertRecipients';

const plant = { id: 'p1', org_id: 'o1' };
const m = (over: Partial<AlertMembership>): AlertMembership => ({
  id: 'm1',
  user_id: 'u1',
  org_id: 'o1',
  plant_id: 'p1',
  role: 'manager',
  notify_machine_down: false,
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
    );
    expect(rows.map((r) => r.membershipId)).toEqual(['a', 'b']);
    expect(rows[1]).toMatchObject({ orgWide: true, on: true, canEnable: true });
  });
  it('only owner and manager memberships can be turned on', () => {
    const rows = alertRowsFor(
      [m({ id: 'l', role: 'lead' }), m({ id: 'v', role: 'viewer' }), m({ id: 'o', role: 'owner' })],
      'u1',
      plant,
    );
    expect(rows.map((r) => [r.role, r.canEnable])).toEqual([
      ['lead', false],
      ['viewer', false],
      ['owner', true],
    ]);
  });
});
