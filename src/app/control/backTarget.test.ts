import { describe, expect, it } from 'vitest';
import { backTarget } from './backTarget';

describe('backTarget', () => {
  it('shows no back button on Home or outside the app', () => {
    expect(backTarget('/control')).toBeNull();
    expect(backTarget('/control/')).toBeNull();
    expect(backTarget('/sign-in')).toBeNull();
  });
  it('gives the bottom-nav tabs a Back to Home (owner 2026-11-09)', () => {
    for (const p of ['/control/washers', '/control/estimates', '/control/queue', '/control/more'])
      expect(backTarget(p)).toBe('/control');
  });
  it('goes to the parent screen from deeper screens', () => {
    expect(backTarget('/control/load-out/entry')).toBe('/control/load-out');
    expect(backTarget('/control/machines')).toBe('/control/washers');
    expect(backTarget('/control/setup/machines')).toBe('/control/more');
    expect(backTarget('/control/people')).toBe('/control/more');
    expect(backTarget('/control/deliveries')).toBe('/control/more');
    expect(backTarget('/control/tasks')).toBe('/control');
    expect(backTarget('/control/alerts')).toBe('/control');
  });
  it('gives the washer station a Back to the washers board', () => {
    expect(backTarget('/station/washer/abc')).toBe('/control/washers');
  });
});
