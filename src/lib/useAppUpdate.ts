import { useEffect, useState } from 'react';
import { entryScript, isNewer } from './appVersion';

const CHECK_EVERY_MS = 5 * 60_000;

/** The entry script this page was started with (built apps only; null in dev). */
function runningScript(): string | null {
  const el = document.querySelector<HTMLScriptElement>('script[type="module"][src*="/index-"]');
  return el ? new URL(el.src, location.href).pathname : null;
}

/**
 * True once the server serves a newer build than the one running. Checks on start, every 5 minutes,
 * and whenever the app comes back to the screen. Never reloads on its own: the person decides
 * (an entry may be half typed).
 */
export function useAppUpdate(): boolean {
  const [available, setAvailable] = useState(false);
  useEffect(() => {
    const running = runningScript();
    if (!running) return;
    let stopped = false;
    const check = async () => {
      try {
        const res = await fetch(`/index.html?v=${Date.now()}`, { cache: 'no-store' });
        if (!res.ok) return;
        const served = entryScript(await res.text());
        if (!stopped && isNewer(running, served)) setAvailable(true);
      } catch {
        // Offline or a hiccup: try again at the next check.
      }
    };
    void check();
    const id = window.setInterval(() => void check(), CHECK_EVERY_MS);
    const onVisible = () => {
      if (document.visibilityState === 'visible') void check();
    };
    document.addEventListener('visibilitychange', onVisible);
    return () => {
      stopped = true;
      window.clearInterval(id);
      document.removeEventListener('visibilitychange', onVisible);
    };
  }, []);
  return available;
}
