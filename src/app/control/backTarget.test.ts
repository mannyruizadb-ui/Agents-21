import { describe, expect, it } from 'vitest';
import { backTarget } from './backTarget';

describe('backTarget', () => {
  it('shows no back button on the bottom-nav tabs', () => {
    for (const p of [
      '/control',
      '/control/',
      '/control/washers',
      '/control/more',
      '/control/queue',
    ])
      expect(backTarget(p)).toBeNull();
  });
  it('goes to the parent screen from deeper screens', () => {
    expect(backTarget('/control/load-out/entry')).toBe('/control/load-out');
    expect(backTarget('/control/setup/pins')).toBe('/control/more');
    expect(backTarget('/control/people')).toBe('/control/more');
    expect(backTarget('/control/tasks')).toBe('/control/more');
    expect(backTarget('/control/alerts')).toBe('/control');
  });
  it('ignores screens outside the control app', () => {
    expect(backTarget('/station/washer/1')).toBeNull();
  });
});
