// Sender tests with a stubbed fetch: no real push service is ever contacted. The round-trip test
// plays the browser: it decrypts the aes128gcm body with the subscription's own keys (RFC 8291) and
// verifies the VAPID JWT with the public key (RFC 8292).
import { assert, assertEquals, assertFalse, assertRejects } from '@std/assert';
import { decrypt, Header } from '@negrel/http-ece';
import { decodeBase64Url, encodeBase64Url } from '@std/encoding/base64url';
import { createSender, importVapidKeys, validSubject } from './push.ts';
import type { PushPayload } from './alerts.ts';

const subtle = crypto.subtle;
const enc = new TextEncoder();

async function newVapidEnv(): Promise<{ pub: string; priv: string }> {
  const kp = await subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, [
    'sign',
    'verify',
  ]);
  const raw = new Uint8Array(await subtle.exportKey('raw', kp.publicKey));
  const jwk = await subtle.exportKey('jwk', kp.privateKey);
  return { pub: encodeBase64Url(raw), priv: jwk.d as string };
}

async function newBrowserSubscription() {
  const kp = await subtle.generateKey({ name: 'ECDH', namedCurve: 'P-256' }, true, ['deriveBits']);
  const pubRaw = new Uint8Array(await subtle.exportKey('raw', kp.publicKey));
  const auth = crypto.getRandomValues(new Uint8Array(16));
  return { kp, pubRaw, auth, p256dh: encodeBase64Url(pubRaw), authB64: encodeBase64Url(auth) };
}

async function hmac(
  key: Uint8Array<ArrayBuffer>,
  data: Uint8Array<ArrayBuffer>,
): Promise<Uint8Array<ArrayBuffer>> {
  const k = await subtle.importKey('raw', key, { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  return new Uint8Array(await subtle.sign('HMAC', k, data));
}

/** The browser side of RFC 8291 §3.4: derive the IKM and decrypt the record. */
async function browserDecrypt(
  body: Uint8Array,
  sub: Awaited<ReturnType<typeof newBrowserSubscription>>,
): Promise<string> {
  const header = Header.fromBytes(body.slice().buffer);
  const asPub = await subtle.importKey(
    'raw',
    new Uint8Array(header.keyid),
    { name: 'ECDH', namedCurve: 'P-256' },
    false,
    [],
  );
  const shared = new Uint8Array(
    await subtle.deriveBits({ name: 'ECDH', public: asPub }, sub.kp.privateKey, 256),
  );
  const prk = await hmac(sub.auth, shared);
  const info = new Uint8Array([
    ...enc.encode('WebPush: info\0'),
    ...sub.pubRaw,
    ...header.keyid,
    1,
  ]);
  const ikm = (await hmac(prk, info)).slice(0, 32);
  const plain = await decrypt(body.slice().buffer, ikm.buffer);
  return new TextDecoder().decode(plain);
}

const payload: PushPayload = {
  title: 'Washer 4 is down',
  body: 'Water pump · since 9:42 PM',
  tag: 'machine-m1',
  url: '/control/washers',
};

function stubFetch(handler: (req: Request) => Response | Promise<Response>) {
  const original = globalThis.fetch;
  const calls: Request[] = [];
  globalThis.fetch = (async (input: RequestInfo | URL, init?: RequestInit) => {
    const req = new Request(input, init);
    calls.push(req.clone());
    return await handler(req);
  }) as typeof fetch;
  return { calls, restore: () => (globalThis.fetch = original) };
}

Deno.test('importVapidKeys: accepts web-push format keys, rejects malformed ones', async () => {
  const { pub, priv } = await newVapidEnv();
  const keys = await importVapidKeys(pub, priv);
  assertEquals(keys.privateKey.type, 'private');
  await assertRejects(() => importVapidKeys(pub.slice(4), priv));
  await assertRejects(() => importVapidKeys(pub, priv.slice(4)));
  await assertRejects(() => importVapidKeys('not base64 !!', priv));
});

Deno.test('validSubject: mailto or https only', () => {
  assert(validSubject('mailto:alerts@example.com'));
  assert(validSubject('https://adb-plantboard.netlify.app'));
  assertFalse(validSubject(''));
  assertFalse(validSubject('alerts@example.com'));
  assertFalse(validSubject('http://example.com'));
  assertFalse(validSubject('mailto:no spaces@example.com'));
});

Deno.test('sender: round trip — headers, VAPID JWT and decryptable payload', async () => {
  const { pub, priv } = await newVapidEnv();
  const keys = await importVapidKeys(pub, priv);
  const sub = await newBrowserSubscription();
  const endpoint = 'https://fcm.googleapis.com/fcm/send/test-token';
  const fake = stubFetch(() => new Response(null, { status: 201 }));
  try {
    const send = createSender(keys, 'mailto:alerts@example.com');
    const result = await send({ endpoint, p256dh: sub.p256dh, auth: sub.authB64 }, payload);
    assertEquals(result, 'ok');
    assertEquals(fake.calls.length, 1);
    const req = fake.calls[0];
    assertEquals(req.url, endpoint);
    assertEquals(req.method, 'POST');
    assertEquals(req.headers.get('TTL'), '3600');
    assertEquals(req.headers.get('Urgency'), 'high');
    assertEquals(req.headers.get('Content-Encoding'), 'aes128gcm');

    // VAPID: "vapid t=<jwt>, k=<public key>"
    const m = /^vapid t=([^,]+), k=(.+)$/.exec(req.headers.get('Authorization') ?? '');
    assert(m, 'vapid authorization header');
    assertEquals(m[2], pub);
    const [h, c, s] = m[1].split('.');
    const claims = JSON.parse(new TextDecoder().decode(decodeBase64Url(c)));
    assertEquals(claims.aud, 'https://fcm.googleapis.com');
    assertEquals(claims.sub, 'mailto:alerts@example.com');
    assert(claims.exp > Date.now() / 1000 && claims.exp <= Date.now() / 1000 + 24 * 3600);
    assert(
      await subtle.verify(
        { name: 'ECDSA', hash: 'SHA-256' },
        keys.publicKey,
        decodeBase64Url(s),
        enc.encode(`${h}.${c}`),
      ),
      'JWT signature verifies with the VAPID public key',
    );

    // The browser can decrypt it, and it is exactly the sw.js payload.
    const body = new Uint8Array(await req.arrayBuffer());
    assertEquals(JSON.parse(await browserDecrypt(body, sub)), payload);
  } finally {
    fake.restore();
  }
});

Deno.test('sender: a fresh ECDH key per message', async () => {
  const { pub, priv } = await newVapidEnv();
  const keys = await importVapidKeys(pub, priv);
  const sub = await newBrowserSubscription();
  const fake = stubFetch(() => new Response(null, { status: 201 }));
  try {
    const send = createSender(keys, 'mailto:alerts@example.com');
    const target = {
      endpoint: 'https://web.push.apple.com/x',
      p256dh: sub.p256dh,
      auth: sub.authB64,
    };
    await send(target, payload);
    await send(target, payload);
    const ids = await Promise.all(
      fake.calls.map(async (r) => encodeBase64Url(Header.fromBytes(await r.arrayBuffer()).keyid)),
    );
    assert(ids[0] !== ids[1], 'as_public differs between messages');
  } finally {
    fake.restore();
  }
});

Deno.test('sender: 404/410 are gone, other errors and exceptions are failed', async () => {
  const { pub, priv } = await newVapidEnv();
  const keys = await importVapidKeys(pub, priv);
  const sub = await newBrowserSubscription();
  const target = {
    endpoint: 'https://fcm.googleapis.com/x',
    p256dh: sub.p256dh,
    auth: sub.authB64,
  };
  const send = createSender(keys, 'mailto:alerts@example.com');
  for (const [status, expected] of [
    [404, 'gone'],
    [410, 'gone'],
    [400, 'failed'],
    [413, 'failed'],
    [429, 'failed'],
    [500, 'failed'],
  ] as const) {
    const fake = stubFetch(() => new Response('nope', { status }));
    try {
      assertEquals(await send(target, payload), expected, String(status));
    } finally {
      fake.restore();
    }
  }
  const fake = stubFetch(() => {
    throw new TypeError('network down');
  });
  try {
    assertEquals(await send(target, payload), 'failed');
  } finally {
    fake.restore();
  }
});
