// "New version available" (owner 2026-11-09): an app left open never picks up a new release on its
// own, so the shell compares the build it is running with the one the server now serves. Pure parts
// here, for tests; the hook is in useAppUpdate.ts.

/** The entry script of a built index.html (e.g. "/assets/index-AbC123.js"), or null. */
export function entryScript(html: string): string | null {
  const m = /<script[^>]+type="module"[^>]+src="([^"]+\/index-[^"]+\.js)"/.exec(html);
  return m?.[1] ?? null;
}

/** True when the server's entry script differs from the one this page loaded. */
export function isNewer(running: string | null, served: string | null): boolean {
  return !!running && !!served && running !== served;
}
