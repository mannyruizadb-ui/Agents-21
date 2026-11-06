import { describe, expect, it } from 'vitest';
import { groupShifts, groupState } from './shiftGroups';

const v = (id: string, area: string, name: string, start: string, days: number[]) => ({
  id,
  name,
  area_name: area,
  start_local: start,
  end_local: '00:00:00',
  days_of_week: days,
});
const shifts = [
  v('we', 'Washroom', 'Evening', '14:00:00', [1, 2, 3, 5, 6]),
  v('we-thu', 'Washroom', 'Evening', '15:00:00', [4]),
  v('wn', 'Washroom', 'Night', '00:00:00', [2, 3, 5, 6]),
  v('fe', 'Finishing', 'Evening', '16:00:00', [1, 2, 3, 5, 6]),
];

describe('shift groups', () => {
  it('groups variants by area + name, in area and time order', () => {
    const g = groupShifts(shifts);
    expect(g.map((x) => `${x.area_name}·${x.name}`)).toEqual([
      'Finishing·Evening',
      'Washroom·Night',
      'Washroom·Evening',
    ]);
    expect(g[2]?.variants.map((x) => x.id)).toEqual(['we', 'we-thu']);
  });
  it('reports all / some / none for a manager', () => {
    const a = [
      { membership_id: 'm', shift_id: 'we', active: true },
      { membership_id: 'm', shift_id: 'we-thu', active: false },
      { membership_id: 'x', shift_id: 'we-thu', active: true },
    ];
    expect(groupState(a, 'm', ['we', 'we-thu'])).toBe('some');
    expect(groupState(a, 'm', ['we'])).toBe('all');
    expect(groupState(a, 'm', ['wn'])).toBe('none');
  });
});
