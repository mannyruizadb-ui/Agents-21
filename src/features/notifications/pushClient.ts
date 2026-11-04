// Browser side of Web Push: service worker, permission, subscribe / unsubscribe. No dependencies.
import { removePushSubscription, savePushSubscription } from './pushApi';
import { pushSupport, subscriptionKeys, urlBase64ToUint8Array, type PushEnv } from './pushSupport';

export const SW_URL = '/sw.js';

/** The browser facts pushSupport() needs. */
export function readPushEnv(): PushEnv {
  const nav = navigator as Navigator & { standalone?: boolean };
  return {
    userAgent: nav.userAgent,
    maxTouchPoints: nav.maxTouchPoints ?? 0,
    hasServiceWorker: 'serviceWorker' in nav,
    hasPushManager: typeof window !== 'undefined' && 'PushManager' in window,
    hasNotification: typeof window !== 'undefined' && 'Notification' in window,
    standaloneDisplay:
      typeof window.matchMedia === 'function' &&
      window.matchMedia('(display-mode: standalone)').matches,
    navigatorStandalone: nav.standalone,
  };
}

export function currentPermission(): NotificationPermission | 'unsupported' {
  return 'Notification' in window ? Notification.permission : 'unsupported';
}

/** Registers /sw.js (push only; it doesn't cache). Safe to call more than once. */
export async function registerServiceWorker(): Promise<ServiceWorkerRegistration | null> {
  if (!('serviceWorker' in navigator)) return null;
  try {
    return await navigator.serviceWorker.register(SW_URL, { scope: '/' });
  } catch {
    return null;
  }
}

async function registration(): Promise<ServiceWorkerRegistration | null> {
  if (!('serviceWorker' in navigator)) return null;
  return (await navigator.serviceWorker.getRegistration('/')) ?? (await registerServiceWorker());
}

/** This device's push subscription, if any. */
export async function currentSubscription(): Promise<PushSubscription | null> {
  try {
    const reg = await registration();
    return (await reg?.pushManager.getSubscription()) ?? null;
  } catch {
    return null;
  }
}

export type TurnOnResult =
  | { ok: true }
  | {
      ok: false;
      reason: 'denied' | 'dismissed' | 'unsupported' | 'subscribe-failed' | 'save-failed';
    };

/**
 * Must run from a tap (iOS requires a user gesture for the permission prompt). Asks permission,
 * subscribes with the VAPID key, then saves the subscription for this account and plant.
 */
export async function turnOnPush(plantId: string, vapidPublicKey: string): Promise<TurnOnResult> {
  if (pushSupport(readPushEnv()) !== 'supported') return { ok: false, reason: 'unsupported' };
  const permission = await Notification.requestPermission();
  if (permission === 'denied') return { ok: false, reason: 'denied' };
  if (permission !== 'granted') return { ok: false, reason: 'dismissed' };
  const reg = await registration();
  if (!reg) return { ok: false, reason: 'unsupported' };
  await navigator.serviceWorker.ready;
  let sub: PushSubscription;
  try {
    sub =
      (await reg.pushManager.getSubscription()) ??
      (await reg.pushManager.subscribe({
        userVisibleOnly: true,
        applicationServerKey: urlBase64ToUint8Array(vapidPublicKey),
      }));
  } catch {
    // The browser's push service couldn't be reached (offline, blocked network, bad key).
    return { ok: false, reason: 'subscribe-failed' };
  }
  const keys = subscriptionKeys(sub.toJSON());
  if (!keys) return { ok: false, reason: 'save-failed' };
  try {
    await savePushSubscription(plantId, keys, navigator.userAgent);
  } catch {
    return { ok: false, reason: 'save-failed' };
  }
  return { ok: true };
}

/** Removes this device's subscription on the server, then in the browser. Throws if the server fails. */
export async function turnOffPush(): Promise<void> {
  const sub = await currentSubscription();
  if (!sub) return;
  await removePushSubscription(sub.endpoint);
  await sub.unsubscribe();
}

/**
 * For sign-out: stop this device getting the signed-out person's alerts. Never blocks sign-out for
 * more than a few seconds. Unsubscribing in the browser happens even if the server call fails, so
 * the old endpoint can't receive anything (the server drops it on its next failed send).
 */
export async function removeThisDevicePush(timeoutMs = 4000): Promise<void> {
  const work = (async () => {
    const sub = await currentSubscription();
    if (!sub) return;
    try {
      await removePushSubscription(sub.endpoint);
    } finally {
      await sub.unsubscribe().catch(() => false);
    }
  })().catch(() => undefined);
  await Promise.race([work, new Promise((r) => setTimeout(r, timeoutMs))]);
}
