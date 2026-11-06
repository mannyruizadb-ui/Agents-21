import { assert, assertEquals, assertFalse } from '@std/assert';
import {
  BUILDERS,
  bearerMatches,
  buildMessage,
  type ClaimedRow,
  type Deps,
  groupByAlert,
  isAllowedPushEndpoint,
  localMachineName,
  localRouteName,
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
// machine_down

const MACHINE = '11111111-1111-1111-1111-111111111111';
// 2026-11-05 02:42 UTC = 21:42 on 2026-11-04 in Miami (EST)
const down = {
  machine_id: MACHINE,
  machine_name: 'Washer 4',
  machine_kind: 'washer',
  area_name: 'Washroom',
  reason_code: 'water_pump',
  reason_label_i18n: { en: 'Water pump', es: 'Bomba de agua' },
  down_since: '2026-11-05T02:42:00Z',
  still_down: true,
};
const ctx = { now: new Date('2026-11-05T02:57:30Z'), timeZone: 'America/New_York' };

/** buildMessage that must produce a message. */
function msg(
  kind: string,
  payload: Record<string, unknown> | null,
  lang: string | null,
): PushPayload {
  const m = buildMessage(kind, payload, lang, ctx);
  if (m === null) throw new Error('expected a message');
  return m;
}

Deno.test('machine_down: English', () => {
  assertEquals(buildMessage('machine_down', down, 'en', ctx), {
    title: 'Washer 4 is down',
    body: 'Water pump · since 9:42 PM',
    tag: `machine-down-${MACHINE}`,
    url: '/control/washers',
  });
});

Deno.test('machine_down: Spanish, including "la 1"', () => {
  const p = msg('machine_down', down, 'es');
  assertEquals(p.title, 'Lavadora 4 está fuera de servicio');
  assert(p.body.startsWith('Bomba de agua · desde las 9:42'), p.body);
  const one = msg('machine_down', { ...down, down_since: '2026-11-05T18:05:00Z' }, 'es-US');
  assert(one.body.includes('desde la 1:05'), one.body);
});

Deno.test('machine_down: unknown language falls back to English', () => {
  assertEquals(msg('machine_down', down, 'ht').title, 'Washer 4 is down');
  assertEquals(msg('machine_down', down, null).title, 'Washer 4 is down');
});

Deno.test('machine_down: reasons — plant labels, presets, never the code', () => {
  const noLabels = { ...down, reason_label_i18n: null };
  assertEquals(msg('machine_down', noLabels, 'es').body.slice(0, 13), 'Bomba de agua');
  const custom = {
    ...down,
    reason_code: 'belt',
    reason_label_i18n: { en: 'Belt broke', es: 'Correa rota' },
  };
  assert(msg('machine_down', custom, 'es').body.startsWith('Correa rota · '));
  const enOnly = { ...down, reason_code: 'belt', reason_label_i18n: { en: 'Belt broke' } };
  assert(msg('machine_down', enOnly, 'es').body.startsWith('Belt broke · '));
  const unknown = { ...down, reason_code: 'something_new', reason_label_i18n: null };
  assertEquals(msg('machine_down', unknown, 'en').body, 'Since 9:42 PM');
  const proto = { ...down, reason_code: '__proto__', reason_label_i18n: null };
  assertEquals(msg('machine_down', proto, 'en').body, 'Since 9:42 PM');
  const junk = { ...down, reason_label_i18n: { en: 42, es: ['x'] } };
  assert(msg('machine_down', junk, 'en').body.startsWith('Water pump'));
  const ctl = { ...down, reason_code: 'x', reason_label_i18n: { en: 'A\nB' } };
  assertEquals(msg('machine_down', ctl, 'en').body, 'A B · since 9:42 PM');
  const long = { ...down, reason_code: 'x', reason_label_i18n: { en: 'y'.repeat(300) } };
  assert(msg('machine_down', long, 'en').body.length < 90);
});

Deno.test('machine_down: odd names, bad time, missing machine id', () => {
  assertEquals(msg('machine_down', { ...down, down_since: 'garbage' }, 'en').body, 'Water pump');
  assertEquals(
    msg('machine_down', { ...down, machine_name: 'W\n4\u0007' }, 'en').title,
    'W 4 is down',
  );
  assertEquals(
    msg('machine_down', { ...down, machine_name: '  ' }, 'en').title,
    'A machine is down',
  );
  assertEquals(
    msg('machine_down', { ...down, machine_name: 'Boiler' }, 'es').title,
    'Boiler está fuera de servicio',
  );
  assert(msg('machine_down', { ...down, machine_name: 'x'.repeat(200) }, 'en').title.length < 80);
  assertEquals(buildMessage('machine_down', { ...down, machine_id: null }, 'en', ctx), null);
});

// ------------------------------------------------------------------------------------------------
// washer_idle

const idle = {
  machine_id: MACHINE,
  machine_name: 'Washer 3',
  area_name: 'Washroom',
  idle_since: '2026-11-05T02:42:00Z',
  still_idle: true,
};

Deno.test('washer_idle: EN/ES with minutes', () => {
  assertEquals(buildMessage('washer_idle', idle, 'en', ctx), {
    title: 'Washer 3 idle 15 min — work waiting',
    body: 'Since 9:42 PM',
    tag: `washer-idle-${MACHINE}`,
    url: '/control/washers',
  });
  const es = msg('washer_idle', idle, 'es');
  assertEquals(es.title, 'Lavadora 3 parada 15 min — hay trabajo');
  assert(es.body.startsWith('Desde las 9:42'), es.body);
});

Deno.test('washer_idle: no usable idle_since drops the minutes; no id is unusable', () => {
  assertEquals(
    msg('washer_idle', { ...idle, idle_since: null }, 'en').title,
    'Washer 3 idle — work waiting',
  );
  assertEquals(msg('washer_idle', { ...idle, idle_since: null }, 'en').body, '');
  const future = { ...idle, idle_since: '2026-11-05T03:30:00Z' };
  assertEquals(msg('washer_idle', future, 'en').title, 'Washer 3 idle — work waiting');
  assertEquals(buildMessage('washer_idle', { ...idle, machine_id: 7 }, 'en', ctx), null);
});

Deno.test('tags differ per kind and per machine', () => {
  const a = msg('machine_down', down, 'en').tag;
  const b = msg('washer_idle', idle, 'en').tag;
  const c = msg('washer_idle', { ...idle, machine_id: 'other' }, 'en').tag;
  assert(a !== b && b !== c);
});

Deno.test('unknown kinds and bad payloads build nothing', () => {
  assertEquals(buildMessage('task_assigned', { text: 'check trucks' }, 'en', ctx), null);
  assertEquals(buildMessage('__proto__', {}, 'en', ctx), null);
  assertEquals(buildMessage('machine_down', null, 'en', ctx), null);
  assertEquals(Object.keys(BUILDERS).sort(), ['machine_down', 'route_loaded', 'washer_idle']);
});

Deno.test('localMachineName: only the seeded washer pattern is translated', () => {
  assertEquals(localMachineName('Washer 6', 'es'), 'Lavadora 6');
  assertEquals(localMachineName('Washer 6', 'en'), 'Washer 6');
  assertEquals(localMachineName('Washer 6 (160 lb)', 'es'), 'Washer 6 (160 lb)');
  assertEquals(localMachineName('Ironer', 'es'), 'Ironer');
});

Deno.test('reason labels match the app (src/locales machines.reasons)', async () => {
  for (const lang of ['en', 'es'] as const) {
    const url = new URL(`../../../src/locales/${lang}.json`, import.meta.url);
    const locale = JSON.parse(await Deno.readTextFile(url));
    assertEquals(REASONS[lang], locale.machines.reasons, `${lang}.json machines.reasons`);
  }
});

// ------------------------------------------------------------------------------------------------
// groupByAlert / run

let seq = 0;
function row(over: Partial<ClaimedRow> = {}): ClaimedRow {
  seq++;
  return {
    alert_id: 'a1',
    kind: 'machine_down',
    payload: { ...down, reason_code: 'leaking', reason_label_i18n: null },
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
    row({ alert_id: 'a2', subscription_id: 'x', kind: 'washer_idle', payload: idle }),
  ]);
  assertEquals(groups.length, 2);
  assertEquals(
    groups[0].rows.map((r) => r.subscription_id),
    ['x', 'y'],
  );
  assertEquals(groups[1].kind, 'washer_idle');
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

const NOW = () => ctx.now;

Deno.test('run: one push per subscription in its language; marks the sent ids', async () => {
  const rows = [
    row({ subscription_id: 's-a', language: 'es' }),
    row({ subscription_id: 's-b' }),
    row({ subscription_id: 's-b' }),
  ];
  const { deps, rec } = mockDeps(rows, () => 'ok');
  const counts = await run(deps, NOW);
  assertEquals(rec.sends.length, 2);
  assertEquals(rec.marks, { a1: ['s-a', 's-b'] });
  assertEquals(counts.alerts, 1);
  assertEquals(counts.sent, 2);
  assertEquals(rec.sends[0].payload.title, 'Lavadora 4 está fuera de servicio');
  assertEquals(rec.sends[1].payload.title, 'Washer 4 is down');
});

Deno.test('run: washer_idle is sent; idle ended or machine back up is stale', async () => {
  const rows = [
    row({ alert_id: 'idle', kind: 'washer_idle', payload: idle, subscription_id: 'x' }),
    row({ alert_id: 'idle-over', kind: 'washer_idle', payload: { ...idle, still_idle: false } }),
    row({ alert_id: 'up', payload: { ...down, still_down: false } }),
    row({ alert_id: 'gone-subject', payload: {} }),
  ];
  const { deps, rec } = mockDeps(rows, () => 'ok');
  const counts = await run(deps, NOW);
  assertEquals(rec.sends.length, 1);
  assertEquals(rec.sends[0].payload.title, 'Washer 3 idle 15 min — work waiting');
  assertEquals(rec.marks, {
    idle: ['x'],
    'idle-over': ['stale'],
    up: ['stale'],
    'gone-subject': ['stale'],
  });
  assertEquals(counts.stale, 3);
});

Deno.test('run: unknown kinds and unusable payloads are marked none and never sent', async () => {
  const rows = [
    row({ alert_id: 'task', kind: 'task_assigned', payload: { text: 'check trucks' } }),
    row({ alert_id: 'nullp', payload: null }),
    row({ alert_id: 'noid', payload: { ...down, machine_id: null } }),
  ];
  const { deps, rec } = mockDeps(rows, () => 'ok');
  const counts = await run(deps, NOW);
  assertEquals(rec.sends.length, 0);
  assertEquals(rec.marks, { task: ['none'], nullp: ['none'], noid: ['none'] });
  assertEquals(counts.unsupported, 3);
});

Deno.test('run: 404/410 revokes the subscription; all failed marks failed', async () => {
  const rows = [
    row({ subscription_id: 'gone', endpoint: 'https://fcm.googleapis.com/gone' }),
    row({ subscription_id: 'err', endpoint: 'https://fcm.googleapis.com/err' }),
  ];
  const { deps, rec } = mockDeps(rows, (t) => (t.endpoint.endsWith('gone') ? 'gone' : 'failed'));
  const counts = await run(deps, NOW);
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
  await run(deps, NOW);
  assertEquals(rec.marks, { a1: ['good'] });
});

Deno.test('run: endpoints off the allow-list are never contacted; marks none', async () => {
  const rows = [
    row({ endpoint: 'https://evil.example/push' }),
    row({ endpoint: 'http://localhost:9/x' }),
  ];
  const { deps, rec } = mockDeps(rows, () => 'ok');
  const counts = await run(deps, NOW);
  assertEquals(rec.sends.length, 0);
  assertEquals(rec.marks, { a1: ['none'] });
  assertEquals(counts.skipped, 2);
});

Deno.test('run: revoke and mark failures are counted, never thrown', async () => {
  const { deps } = mockDeps([row()], () => 'gone', { markThrows: true, revokeThrows: true });
  const counts = await run(deps, NOW);
  assertEquals(counts.unmarked, 1);
  assertEquals(counts.revoked, 0);
});

Deno.test('run: nothing claimed, nothing done', async () => {
  const { deps, rec } = mockDeps([], () => 'ok');
  const counts = await run(deps, NOW);
  assertEquals(counts.alerts, 0);
  assertEquals(rec.marks, {});
});

// ------------------------------------------------------------------------------------------------
// route_loaded

const ROUTE = '22222222-2222-2222-2222-222222222222';
// loaded 2026-11-06 08:12 UTC = 3:12 AM in Miami (EST)
const loaded = {
  route_id: ROUTE,
  route_name: 'Route 21',
  load_time: '03:30:00',
  load_date: '2026-11-06',
  loaded_at: '2026-11-06T08:12:00Z',
};

Deno.test('route_loaded: EN/ES text, tag per route and day', () => {
  assertEquals(msg('route_loaded', loaded, 'en'), {
    title: 'Route 21 loaded',
    body: '3:30 AM truck · loaded 3:12 AM',
    tag: `route-${ROUTE}-2026-11-06`,
    url: '/control',
  });
  const es = msg('route_loaded', loaded, 'es');
  assertEquals(es.title, 'Ruta 21 cargada');
  assert(
    /^Camión de las 3:30 a\.?\s?m\.? · cargada a las 3:12 a\.?\s?m\.?$/.test(es.body),
    es.body,
  );
  const one = msg('route_loaded', { ...loaded, loaded_at: '2026-11-06T06:05:00Z' }, 'es');
  assert(one.body.includes('cargada a la 1:05'), one.body);
});

Deno.test('route_loaded: partial or bad payloads', () => {
  assertEquals(msg('route_loaded', { ...loaded, load_time: '25:00' }, 'en').body, 'Loaded 3:12 AM');
  assertEquals(msg('route_loaded', { ...loaded, loaded_at: null }, 'en').body, '3:30 AM truck');
  assertEquals(
    msg('route_loaded', { ...loaded, route_name: 'Kendall' }, 'es').title,
    'Kendall cargada',
  );
  assertEquals(msg('route_loaded', { ...loaded, route_name: '' }, 'en').title, 'A route loaded');
  assertEquals(buildMessage('route_loaded', { ...loaded, route_id: null }, 'en', ctx), null);
  assertEquals(buildMessage('route_loaded', { ...loaded, load_date: 'x/../y' }, 'en', ctx), null);
});

Deno.test('route_loaded: never stale', async () => {
  const { deps, rec } = mockDeps(
    [row({ alert_id: 'r', kind: 'route_loaded', payload: loaded, subscription_id: 'x' })],
    () => 'ok',
  );
  await run(deps, NOW);
  assertEquals(rec.marks, { r: ['x'] });
  assertEquals(rec.sends[0].payload.title, 'Route 21 loaded');
});

Deno.test('localRouteName: only the seeded route pattern is translated', () => {
  assertEquals(localRouteName('Route 4', 'es'), 'Ruta 4');
  assertEquals(localRouteName('Route 4', 'en'), 'Route 4');
  assertEquals(localRouteName('Route 4 extra', 'es'), 'Route 4 extra');
});
