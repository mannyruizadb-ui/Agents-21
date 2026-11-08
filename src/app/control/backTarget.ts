// Back button (owner 2026-11-06: "there's no clear back button"). The bottom-nav tabs are top level
// and get none; every other control screen shows one. Pure module, for tests.

/** The bottom-nav tabs: no back button there. */
const TOP_LEVEL = new Set([
  '/control',
  '/control/washers',
  '/control/estimates',
  '/control/queue',
  '/control/load-out',
  '/control/more',
]);

/** Where Back goes when there is no in-app history (opened from a notification or a bookmark). */
export function backTarget(pathname: string): string | null {
  const path = pathname.replace(/\/+$/, '') || '/';
  if (!path.startsWith('/control') || TOP_LEVEL.has(path)) return null;
  if (path.startsWith('/control/load-out/')) return '/control/load-out';
  if (path === '/control/alerts') return '/control';
  return '/control/more';
}
