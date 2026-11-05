import { assert, assertEquals, assertFalse } from '@std/assert';
import {
  bearerMatches,
  buildPayload,
  type ClaimedRow,
  type Deps,
  groupByAlert,
  isAllowedPushEndpoint,
  REASONS,
  type PushPayload,
  type PushTarget,
  run,
  type SendResult,
} from './alerts.ts';

// ------------------------------------------------------------------------------------------------
// bearerMatches

Deno.test('bearerMatches: exact secret only', async () => {
  const secret = 's3cret-value-with-enough-length';
  assert(await bearerMatches(`Bearer ${secret}`, secret));
  assertFalse(await bearerMatches(`Bearer ${secret}x`, secret));
  assertFalse(await bearerMatches(`Bearer ${secret.slice(0, -1)}`, secret));
  assertFalse(await bearerMatches(`bearer ${secret}`, secret));
  assertFalse(await bearerMatches(secret, secret));
  assertFalse(await bearerMatches(null, secret));
  assertFalse(await bearerMatches('Bearer ', secret));
});

Deno.test('bearerMatches: an empty configured secret never matches', async () => {
  assertFalse(await bearerMatches('Bearer ', ''));
  assertFalse(await bearerMatches('Bearer anything', ''));
});

// ------------------------------------------------------------------------------------------------
// isAllowedPushEndpoint

Deno.test('isAllowedPushEndpoint: the four push services', () => {
  for (const ok of [
    'https://fcm.googleapis.com/fcm/send/abc:def',
    'https://updates.push.services.mozilla.com/wpush/v2/gAAA',
    'https://web.push.apple.com/QGx1',
    'https://api.push.apple.com/x',
    'https://wns2-by3p.notify.windows.com/w/?token=abc',
    'https://FCM.googleapis.com/fcm/send/abc',
  ]) {
    assert(isAllowedPushEndpoint(ok), ok);
  }
});

Deno.test('isAllowedPushEndpoint: rejects everything else', () => {
  for (const bad of [
    'http://fcm.googleapis.com/fcm/send/abc',
    'https://fcm.googleapis.com:8443/fcm/send/abc',
    'https://user:pw@fcm.googleapis.com/x',
    'https://evil.com/fcm.googleapis.com',
    'https://fcm.googleapis.com.evil.com/x',
    'https://push.apple.com/x',
    'https://evilpush.apple.com/x',
    'https://notify.windows.com/x',
    'https://localhost/x',
    'https://127.0.0.1/x',
    'not a url',
    '',
  ]) {
    assertFalse(isAllowedPushEndpoint(bad), bad);
  }
});

// ------------------------------------------------------------------------------------------------
// buildPayload

const base = {
  machine_id: '11111111-1111-1111-1111-111111111111',
  machine_name: 'Washer 4',
  reason_code: 'water_pump',
  // 2026-11-05 02:42 UTC = 21:42 on 2026-11-04 in Miami (EST)
  down_since: '2026-11-05T02:42:00Z',
  language: 'en',
};

Deno.test('buildPayload: English', () => {
  assertEquals(buildPayload(base), {
    title: 'Washer 4 is down',
    body: 'Water pump · since 9:42 PM',
    tag: 'machine-11111111-1111-1111-1111-111111111111',
    url: '/control/washers',
  });
});

Deno.test('buildPayload: Spanish, including "la 1"', () => {
  const p = buildPayload({ ...base, language: 'es' });
  assertEquals(p.title, 'Washer 4 está fuera de servicio');
  assert(p.body.startsWith('Bomba de agua · desde las 9:42'), p.body);
  const one = buildPayload({ ...base, language: 'es-US', down_since: '2026-11-05T18:05:00Z' });
  assert(one.body.includes('desde la 1:05'), one.body);
});

Deno.test('buildPayload: unknown language falls back to English', () => {
  assertEquals(buildPayload({ ...base, language: 'ht' }).title, 'Washer 4 is down');
  assertEquals(buildPayload({ ...base, language: null }).title, 'Washer 4 is down');
});

Deno.test('buildPayload: unknown or missing reason never echoes the code', () => {
  const p = buildPayload({ ...base, reason_code: 'something_new' });
  assertEquals(p.body, 'Since 9:42 PM');
  assertEquals(
    buildPayload({ ...base, reason_code: null, language: 'es' }).body.slice(0, 9),
    'Desde las',
  );
  assertEquals(buildPayload({ ...base, reason_code: '__proto__' }).body, 'Since 9:42 PM');
});

Deno.test('buildPayload: other, bad time, odd names', () => {
  assertEquals(buildPayload({ ...base, reason_code: 'other' }).body, 'Other · since 9:42 PM');
  assertEquals(buildPayload({ ...base, down_since: 'garbage' }).body, 'Water pump');
  assertEquals(buildPayload({ ...base, machine_name: 'W\n4\u0007' }).title, 'W 4 is down');
  assertEquals(buildPayload({ ...base, machine_name: '  ' }).title, 'A machine is down');
  assert(buildPayload({ ...base, machine_name: 'x'.repeat(200) }).title.length < 80);
});

// ------------------------------------------------------------------------------------------------
// groupByAlert / run

let seq = 0;
function row(over: Partial<ClaimedRow> = {}): ClaimedRow {
  seq++;
  return {
    alert_id: 'a1',
    machine_id: 'm1',
    machine_name: 'Washer 4',
    reason_code: 'leaking',
    down_since: '2026-11-05T02:42:00Z',
    still_down: true,
    subscription_id: `s${seq}`,
    language: 'en',
    endpoint: `https://fcm.googleapis.com/fcm/send/${seq}`,
    p256dh: 'p',
    auth: 'a',
    ...over,
  };
}

Deno.test('groupByAlert: one group per alert, duplicate subscriptions dropped', () => {
  const groups = groupByAlert([
    row({ alert_id: 'a1', subscription_id: 'x' }),
    row({ alert_id: 'a1', subscription_id: 'x' }),
    row({ alert_id: 'a1', subscription_id: 'y' }),
    row({ alert_id: 'a2', subscription_id: 'x', still_down: false }),
  ]);
  assertEquals(groups.length, 2);
  assertEquals(
    groups[0].rows.map((r) => r.subscription_id),
    ['x', 'y'],
  );
  assert(groups[0].stillDown);
  assertFalse(groups[1].stillDown);
});

interface Recorder {
  sends: { target: PushTarget; payload: PushPayload }[];
  revoked: string[];
  marks: Record<string, string[]>;
}

function mockDeps(
  rows: ClaimedRow[],
  results: (target: PushTarget) => SendResult | Promise<SendResult>,
  opts: { markThrows?: boolean; revokeThrows?: boolean } = {},
): { deps: Deps; rec: Recorder } {
  const rec: Recorder = { sends: [], revoked: [], marks: {} };
  const deps: Deps = {
    claim: () => Promise.resolve(rows),
    send: async (target, payload) => {
      rec.sends.push({ target, payload });
      return await results(target);
    },
    revoke: (id) => {
      if (opts.revokeThrows) return Promise.reject(new Error('x'));
      rec.revoked.push(id);
      return Promise.resolve();
    },
    mark: (id, recipients) => {
      if (opts.markThrows) return Promise.reject(new Error('x'));
      rec.marks[id] = [...recipients].sort();
      return Promise.resolve(true);
    },
  };
  return { deps, rec };
}

Deno.test('run: sends one push per subscription and marks the sent ids', async () => {
  const rows = [
    row({ subscription_id: 's-a', language: 'es' }),
    row({ subscription_id: 's-b' }),
    row({ subscription_id: 's-b' }),
  ];
  const { deps, rec } = mockDeps(rows, () => 'ok');
  const counts = await run(deps);
  assertEquals(rec.sends.length, 2);
  assertEquals(rec.marks, { a1: ['s-a', 's-b'] });
  assertEquals(counts.alerts, 1);
  assertEquals(counts.sent, 2);
  assertEquals(rec.sends[0].payload.title, 'Washer 4 está fuera de servicio');
  assertEquals(rec.sends[1].payload.title, 'Washer 4 is down');
});

Deno.test('run: a machine already back up is marked stale and nothing is sent', async () => {
  const { deps, rec } = mockDeps(
    [row({ still_down: false }), row({ still_down: false })],
    () => 'ok',
  );
  const counts = await run(deps);
  assertEquals(rec.sends.length, 0);
  assertEquals(rec.marks, { a1: ['stale'] });
  assertEquals(counts.stale, 1);
});

Deno.test('run: 404/410 revokes the subscription; all failed marks failed', async () => {
  const rows = [
    row({ subscription_id: 'gone', endpoint: 'https://fcm.googleapis.com/gone' }),
    row({ subscription_id: 'err', endpoint: 'https://fcm.googleapis.com/err' }),
  ];
  const { deps, rec } = mockDeps(rows, (t) => (t.endpoint.endsWith('gone') ? 'gone' : 'failed'));
  const counts = await run(deps);
  assertEquals(rec.revoked, ['gone']);
  assertEquals(rec.marks, { a1: ['failed'] });
  assertEquals(counts.failed, 2);
  assertEquals(counts.revoked, 1);
});

Deno.test('run: partial success marks only the ids that got the push', async () => {
  const rows = [row({ subscription_id: 'good' }), row({ subscription_id: 'bad' })];
  const { deps, rec } = mockDeps(rows, (t) => {
    if (t.endpoint === rows[1].endpoint) throw new Error('network');
    return 'ok';
  });
  await run(deps);
  assertEquals(rec.marks, { a1: ['good'] });
});

Deno.test('run: endpoints off the allow-list are never contacted; marks none', async () => {
  const rows = [
    row({ endpoint: 'https://evil.example/push' }),
    row({ endpoint: 'http://localhost:9/x' }),
  ];
  const { deps, rec } = mockDeps(rows, () => 'ok');
  const counts = await run(deps);
  assertEquals(rec.sends.length, 0);
  assertEquals(rec.marks, { a1: ['none'] });
  assertEquals(counts.skipped, 2);
});

Deno.test('run: every claimed alert is marked, several alerts at once', async () => {
  const rows = [
    row({ alert_id: 'a1', subscription_id: 'x' }),
    row({ alert_id: 'a2', subscription_id: 'x', still_down: false }),
    row({ alert_id: 'a3', subscription_id: 'y', endpoint: 'https://bad.example/' }),
  ];
  const { deps, rec } = mockDeps(rows, () => 'ok');
  await run(deps);
  assertEquals(rec.marks, { a1: ['x'], a2: ['stale'], a3: ['none'] });
});

Deno.test('run: revoke and mark failures are counted, never thrown', async () => {
  const { deps } = mockDeps([row()], () => 'gone', { markThrows: true, revokeThrows: true });
  const counts = await run(deps);
  assertEquals(counts.unmarked, 1);
  assertEquals(counts.revoked, 0);
});

Deno.test('run: nothing claimed, nothing done', async () => {
  const { deps, rec } = mockDeps([], () => 'ok');
  const counts = await run(deps);
  assertEquals(counts.alerts, 0);
  assertEquals(rec.marks, {});
});

Deno.test('reason labels match the app (src/locales machines.reasons)', async () => {
  for (const lang of ['en', 'es'] as const) {
    const url = new URL(`../../../src/locales/${lang}.json`, import.meta.url);
    const locale = JSON.parse(await Deno.readTextFile(url));
    assertEquals(REASONS[lang], locale.machines.reasons, `${lang}.json machines.reasons`);
  }
});
