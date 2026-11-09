import { describe, expect, it } from 'vitest';
import { entryScript, isNewer } from './appVersion';

describe('app version check', () => {
  const html = (h: string) =>
    `<!doctype html><head><script type="module" crossorigin src="/assets/index-${h}.js"></script></head>`;
  it('finds the entry script of a build', () => {
    expect(entryScript(html('AbC123'))).toBe('/assets/index-AbC123.js');
    expect(entryScript('<html></html>')).toBeNull();
  });
  it('flags a new build only when both are known and differ', () => {
    expect(isNewer('/assets/index-a.js', '/assets/index-b.js')).toBe(true);
    expect(isNewer('/assets/index-a.js', '/assets/index-a.js')).toBe(false);
    expect(isNewer(null, '/assets/index-b.js')).toBe(false);
    expect(isNewer('/assets/index-a.js', null)).toBe(false);
  });
});
