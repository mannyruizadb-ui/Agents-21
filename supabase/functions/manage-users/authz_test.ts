import { assertEquals } from '@std/assert';
import { canManageTarget, ownsPlant, type Membership } from './authz.ts';

const ORG = 'org-1';
const OTHER_ORG = 'org-2';
const P1 = { id: 'plant-1', org_id: ORG };
const P2 = { id: 'plant-2', org_id: ORG };
const X1 = { id: 'plant-x', org_id: OTHER_ORG };

const m = (role: Membership['role'], plant: string | null, org = ORG): Membership => ({
  org_id: org,
  plant_id: plant,
  role,
});

Deno.test('ownsPlant: plant owner, org-wide owner; never other roles or tenants', () => {
  assertEquals(ownsPlant([m('owner', 'plant-1')], P1), true);
  assertEquals(ownsPlant([m('owner', null)], P1), true);
  assertEquals(ownsPlant([m('owner', null)], P2), true);
  assertEquals(ownsPlant([m('owner', 'plant-1')], P2), false);
  for (const role of ['manager', 'lead', 'viewer', 'display'] as const) {
    assertEquals(ownsPlant([m(role, 'plant-1')], P1), false, role);
    assertEquals(ownsPlant([m(role, null)], P1), false, role);
  }
  // Cross-tenant: an org-wide owner of another org, or a forged plant/org pair.
  assertEquals(ownsPlant([m('owner', null, OTHER_ORG)], P1), false);
  assertEquals(ownsPlant([m('owner', 'plant-1', OTHER_ORG)], P1), false);
  assertEquals(ownsPlant([m('owner', null)], X1), false);
  assertEquals(ownsPlant([], P1), false);
});

// [description, caller memberships, target memberships, plant, expected]
const matrix: [string, Membership[], Membership[], typeof P1, boolean][] = [
  ['plant owner → lead in plant', [m('owner', 'plant-1')], [m('lead', 'plant-1')], P1, true],
  ['plant owner → manager in plant', [m('owner', 'plant-1')], [m('manager', 'plant-1')], P1, true],
  ['plant owner → co-owner in plant', [m('owner', 'plant-1')], [m('owner', 'plant-1')], P1, true],
  ['org owner → lead in plant', [m('owner', null)], [m('lead', 'plant-1')], P1, true],
  ['org owner → org-wide manager', [m('owner', null)], [m('manager', null)], P1, true],
  [
    'org owner → member of 2 plants',
    [m('owner', null)],
    [m('lead', 'plant-1'), m('lead', 'plant-2')],
    P1,
    true,
  ],
  [
    'plant owner → org-wide owner (takeover)',
    [m('owner', 'plant-1')],
    [m('owner', null)],
    P1,
    false,
  ],
  ['plant owner → org-wide viewer', [m('owner', 'plant-1')], [m('viewer', null)], P1, false],
  [
    'plant owner → also in other plant',
    [m('owner', 'plant-1')],
    [m('lead', 'plant-1'), m('lead', 'plant-2')],
    P1,
    false,
  ],
  [
    'owner of both plants → member of both',
    [m('owner', 'plant-1'), m('owner', 'plant-2')],
    [m('lead', 'plant-1'), m('lead', 'plant-2')],
    P1,
    true,
  ],
  [
    'plant owner → user only in other plant',
    [m('owner', 'plant-1')],
    [m('lead', 'plant-2')],
    P1,
    false,
  ],
  ['plant owner → user with no membership', [m('owner', 'plant-1')], [], P1, false],
  ['plant owner → display account', [m('owner', 'plant-1')], [m('display', 'plant-1')], P1, false],
  ['manager → lead', [m('manager', 'plant-1')], [m('lead', 'plant-1')], P1, false],
  ['lead → lead', [m('lead', 'plant-1')], [m('lead', 'plant-1')], P1, false],
  ['viewer → lead', [m('viewer', 'plant-1')], [m('lead', 'plant-1')], P1, false],
  ['owner of other org → lead', [m('owner', null, OTHER_ORG)], [m('lead', 'plant-1')], P1, false],
  [
    'plant owner → target in other org too',
    [m('owner', 'plant-1')],
    [m('lead', 'plant-1'), m('lead', 'plant-x', OTHER_ORG)],
    P1,
    false,
  ],
];

for (const [name, caller, target, plant, expected] of matrix) {
  Deno.test(`canManageTarget: ${name} = ${expected}`, () => {
    assertEquals(canManageTarget('caller', caller, 'target', target, plant), expected);
  });
}

Deno.test('canManageTarget: revoked memberships outside scope still block (M3)', () => {
  const revoked = (r: Membership): Membership => ({ ...r, revoked_at: '2026-11-01T00:00:00Z' });
  // Revoked lead in plant-2 + active lead in plant-1, caller owns plant-1 only → refused.
  assertEquals(
    canManageTarget(
      'caller',
      [m('owner', 'plant-1')],
      'target',
      [revoked(m('lead', 'plant-2')), m('lead', 'plant-1')],
      P1,
    ),
    false,
  );
  // Revoked org-wide owner row → refused for a plant owner.
  assertEquals(
    canManageTarget(
      'caller',
      [m('owner', 'plant-1')],
      'target',
      [revoked(m('owner', null)), m('lead', 'plant-1')],
      P1,
    ),
    false,
  );
  // An org-wide owner covers both, so it is allowed.
  assertEquals(
    canManageTarget(
      'caller',
      [m('owner', null)],
      'target',
      [revoked(m('lead', 'plant-2')), m('lead', 'plant-1')],
      P1,
    ),
    true,
  );
  // At least one ACTIVE in-scope row is required: only revoked rows in plant-1 → refused.
  assertEquals(
    canManageTarget(
      'caller',
      [m('owner', 'plant-1')],
      'target',
      [revoked(m('lead', 'plant-1'))],
      P1,
    ),
    false,
  );
  // Revoked rows in scope alongside an active one are fine.
  assertEquals(
    canManageTarget(
      'caller',
      [m('owner', 'plant-1')],
      'target',
      [revoked(m('viewer', 'plant-1')), m('lead', 'plant-1')],
      P1,
    ),
    true,
  );
});

Deno.test('canManageTarget: never yourself', () => {
  assertEquals(canManageTarget('me', [m('owner', null)], 'me', [m('owner', null)], P1), false);
});
