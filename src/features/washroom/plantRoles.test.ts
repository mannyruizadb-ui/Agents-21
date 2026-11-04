import { describe, expect, it } from 'vitest';
import { rolesOnPlant } from './plantRoles';

const plant = { id: 'p1', org_id: 'o1' };

describe('rolesOnPlant', () => {
  it('collects plant-scoped and org-wide roles of the same org only', () => {
    const roles = rolesOnPlant(
      [
        { org_id: 'o1', plant_id: 'p1', role: 'manager' },
        { org_id: 'o1', plant_id: null, role: 'viewer' },
        { org_id: 'o1', plant_id: 'p2', role: 'owner' },
        { org_id: 'o2', plant_id: null, role: 'owner' },
        { org_id: 'o1', plant_id: 'p1', role: 'display' },
      ],
      plant,
    );
    expect([...roles].sort()).toEqual(['manager', 'viewer']);
  });
  it('is empty without a plant', () => {
    expect(rolesOnPlant([{ org_id: 'o1', plant_id: null, role: 'owner' }], undefined).size).toBe(0);
  });
});
