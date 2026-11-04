// Web Push support detection (machine-down alerts, owner 2026-11-04). Pure module: the browser facts
// are passed in, so the logic is unit-tested without a browser.
// iOS/iPadOS allow web push only for a site added to the Home Screen, from iOS 16.4.

export interface PushEnv {
  userAgent: string;
  /** navigator.maxTouchPoints (iPadOS reports a Mac user agent but has touch). */
  maxTouchPoints: number;
  hasServiceWorker: boolean;
  hasPushManager: boolean;
  hasNotification: boolean;
  /** matchMedia('(display-mode: standalone)').matches */
  standaloneDisplay: boolean;
  /** navigator.standalone (iOS Safari only). */
  navigatorStandalone: boolean | undefined;
}

export type PushSupport =
  | 'supported'
  /** iPhone/iPad, but opened in Safari: add to the Home Screen first. */
  | 'ios-install'
  /** iPhone/iPad older than 16.4: no web push at all. */
  | 'ios-update'
  | 'unsupported';

export function isIOS(userAgent: string, maxTouchPoints: number): boolean {
  if (/iPhone|iPad|iPod/.test(userAgent)) return true;
  // iPadOS 13+ asks for the desktop site: a Mac user agent on a touch screen.
  return /Macintosh/.test(userAgent) && maxTouchPoints > 1;
}

/** [major, minor] from "OS 16_4" or "Version/16.4"; null when unknown. */
export function iosVersion(userAgent: string): [number, number] | null {
  const m = /OS (\d+)_(\d+)/.exec(userAgent) ?? /Version\/(\d+)\.(\d+)/.exec(userAgent);
  return m ? [Number(m[1]), Number(m[2])] : null;
}

/** Opened as an installed app (Home Screen / installed PWA), not in a browser tab. */
export function isInstalled(
  env: Pick<PushEnv, 'standaloneDisplay' | 'navigatorStandalone'>,
): boolean {
  return env.standaloneDisplay || env.navigatorStandalone === true;
}

export function pushSupport(env: PushEnv): PushSupport {
  const apis = env.hasServiceWorker && env.hasPushManager && env.hasNotification;
  if (isIOS(env.userAgent, env.maxTouchPoints)) {
    const v = iosVersion(env.userAgent);
    if (v && (v[0] < 16 || (v[0] === 16 && v[1] < 4))) return 'ios-update';
    if (!isInstalled(env)) return 'ios-install';
    return apis ? 'supported' : 'unsupported';
  }
  return apis ? 'supported' : 'unsupported';
}

/** VAPID public key (base64url) → the bytes PushManager.subscribe wants. */
export function urlBase64ToUint8Array(base64Url: string): Uint8Array<ArrayBuffer> {
  const padding = '='.repeat((4 - (base64Url.length % 4)) % 4);
  const base64 = (base64Url + padding).replace(/-/g, '+').replace(/_/g, '/');
  const raw = atob(base64);
  const out = new Uint8Array(new ArrayBuffer(raw.length));
  for (let i = 0; i < raw.length; i++) out[i] = raw.charCodeAt(i);
  return out;
}

export interface SubscriptionKeys {
  endpoint: string;
  p256dh: string;
  auth: string;
}

/** What save_push_subscription needs, from PushSubscription.toJSON(); null if incomplete. */
export function subscriptionKeys(json: {
  endpoint?: string | null;
  keys?: Record<string, string | undefined> | null;
}): SubscriptionKeys | null {
  const endpoint = json.endpoint ?? '';
  const p256dh = json.keys?.p256dh ?? '';
  const auth = json.keys?.auth ?? '';
  if (!/^https:\/\//.test(endpoint) || !p256dh || !auth) return null;
  return { endpoint, p256dh, auth };
}
