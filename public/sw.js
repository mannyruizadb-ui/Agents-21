/* PlantBoard service worker (hand-written; no build step, no dependencies).
 * Only does push notifications for now (machine-down alerts, owner 2026-11-04). It has no fetch
 * handler, so it never caches or changes how pages load.
 *
 * Push payload (JSON, sent by the future Edge Function):
 *   { "title": "Washer 4 is down", "body": "Water pump", "machine_id": "<uuid>",
 *     "tag": "machine-<uuid>" (optional), "url": "/control/washers" (optional, same-site path) }
 * The tag is per machine, so a repeat alert for the same machine replaces the older one.
 */

const DEFAULT_URL = '/control/washers';

self.addEventListener('install', () => {
  self.skipWaiting();
});

self.addEventListener('activate', (event) => {
  event.waitUntil(self.clients.claim());
});

function readPayload(event) {
  if (!event.data) return {};
  try {
    return event.data.json();
  } catch {
    return { body: event.data.text() };
  }
}

/** Only same-site paths are opened from a notification. */
function safePath(url) {
  return typeof url === 'string' && url.startsWith('/') && !url.startsWith('//')
    ? url
    : DEFAULT_URL;
}

self.addEventListener('push', (event) => {
  const data = readPayload(event);
  const title = typeof data.title === 'string' && data.title ? data.title : 'PlantBoard';
  const tag =
    typeof data.tag === 'string' && data.tag
      ? data.tag
      : typeof data.machine_id === 'string'
        ? `machine-${data.machine_id}`
        : 'plantboard';
  event.waitUntil(
    self.registration.showNotification(title, {
      body: typeof data.body === 'string' ? data.body : '',
      icon: '/icons/icon-192.png',
      badge: '/icons/badge-96.png',
      tag,
      renotify: true,
      data: { url: safePath(data.url) },
    }),
  );
});

self.addEventListener('notificationclick', (event) => {
  event.notification.close();
  const path = safePath(event.notification.data && event.notification.data.url);
  const target = new URL(path, self.location.origin).href;
  event.waitUntil(
    (async () => {
      const windows = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
      for (const client of windows) {
        if (new URL(client.url).origin === self.location.origin && 'focus' in client) {
          await client.focus();
          if ('navigate' in client && client.url !== target) {
            try {
              await client.navigate(target);
            } catch {
              // an uncontrolled window can't be navigated; it is focused anyway
            }
          }
          return;
        }
      }
      await self.clients.openWindow(target);
    })(),
  );
});
