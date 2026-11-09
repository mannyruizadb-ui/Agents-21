// Back button (owner 2026-11-06, widened 2026-11-09: "back buttons on every screen that it's needed").
// Every control screen except Home shows one, the bottom-nav tabs included, and so does the washer
// station. Pure module, for tests.

/** The bottom-nav tabs: Back goes Home when there is no in-app history. */
const TABS = new Set([
  '/control/washers',
  '/control/estimates',
  '/control/queue',
  '/control/load-out',
  '/control/more',
]);

/**
 * Where Back goes when there is no in-app history (opened from a notification or a bookmark);
 * null = no Back button (Home, and screens outside the app).
 */
export function backTarget(pathname: string): string | null {
  const path = pathname.replace(/\/+$/, '') || '/';
  if (path.startsWith('/station/')) return '/control/washers';
  if (!path.startsWith('/control') || path === '/control') return null;
  if (TABS.has(path)) return '/control';
  if (path.startsWith('/control/load-out/')) return '/control/load-out';
  if (path === '/control/machines') return '/control/washers';
  if (path === '/control/alerts' || path === '/control/tasks') return '/control';
  return '/control/more';
}
