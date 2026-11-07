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
  assertEquals(buildMessage('task_rescheduled', { task_id: 't' }, 'en', ctx), null);
  assertEquals(buildMessage('__proto__', {}, 'en', ctx), null);
  assertEquals(buildMessage('machine_down', null, 'en', ctx), null);
  assertEquals(Object.keys(BUILDERS).sort(), [
    'account_locked',
    'customer_delivery',
    'estimate_entered',
    'machine_down',
    'off_queue_start',
    'rewash_added',
    'route_loaded',
    'task_assigned',
    'task_done',
    'washer_idle',
  ]);
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
    row({ alert_id: 'task', kind: 'task_rescheduled', payload: { task_id: 't', body: 'x' } }),
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

// ------------------------------------------------------------------------------------------------
// task_assigned / task_done

const TASK = '33333333-3333-3333-3333-333333333333';
const task = {
  task_id: TASK,
  body: 'Check all parked trucks',
  to_on_duty: true,
  created_at: '2026-11-06T08:00:00Z',
  reminder: 0,
  done_at: null,
};

Deno.test('task_assigned: new task and reminders share one tag', () => {
  assertEquals(msg('task_assigned', task, 'en'), {
    title: 'New task',
    body: 'Check all parked trucks',
    tag: `task-${TASK}`,
    url: '/control/tasks',
  });
  assertEquals(msg('task_assigned', task, 'es').title, 'Nueva tarea');
  const r = msg('task_assigned', { ...task, reminder: 2 }, 'en');
  assertEquals(r.title, 'Reminder: task still open');
  assertEquals(r.tag, `task-${TASK}`);
  assertEquals(
    msg('task_assigned', { ...task, reminder: 1 }, 'es').title,
    'Recordatorio: tarea pendiente',
  );
  assertEquals(msg('task_assigned', { ...task, reminder: null }, 'en').title, 'New task');
  assertEquals(msg('task_assigned', { ...task, reminder: '3' }, 'en').title, 'New task');
});

Deno.test('task text is cleaned and capped', () => {
  assertEquals(msg('task_assigned', { ...task, body: 'a\n\tb\u0007' }, 'en').body, 'a b');
  const long = msg('task_assigned', { ...task, body: 'z'.repeat(200) }, 'en').body;
  assertEquals(long.length, 120);
  assert(long.endsWith('…'));
  assertEquals(buildMessage('task_assigned', { ...task, task_id: null }, 'en', ctx), null);
});

Deno.test('task_done: text plus done time; never the note', () => {
  // 2026-11-06 08:12 UTC = 3:12 AM Miami
  const done = { ...task, done_at: '2026-11-06T08:12:00Z', note: 'secret note', done_by: 'Denise' };
  const en = msg('task_done', done, 'en');
  assertEquals(en, {
    title: 'Task done',
    body: 'Check all parked trucks · done 3:12 AM',
    tag: `task-${TASK}`,
    url: '/control/tasks',
  });
  const es = msg('task_done', done, 'es');
  assertEquals(es.title, 'Tarea hecha');
  assert(/^Check all parked trucks · hecha a las 3:12/.test(es.body), es.body);
  assert(
    !JSON.stringify([en, es]).includes('secret') && !JSON.stringify([en, es]).includes('Denise'),
  );
  assertEquals(msg('task_done', { ...task, done_at: null }, 'en').body, 'Check all parked trucks');
  assertEquals(msg('task_done', { ...done, body: '' }, 'en').body, 'Done 3:12 AM');
  assert(msg('task_done', { ...done, body: 'q'.repeat(200) }, 'en').body.length <= 120);
});

Deno.test('run: task kinds are sent and never stale', async () => {
  const { deps, rec } = mockDeps(
    [
      row({ alert_id: 't1', kind: 'task_assigned', payload: task, subscription_id: 'x' }),
      row({
        alert_id: 't2',
        kind: 'task_done',
        payload: { ...task, done_at: '2026-11-06T08:12:00Z' },
        subscription_id: 'y',
      }),
    ],
    () => 'ok',
  );
  const counts = await run(deps, NOW);
  assertEquals(rec.marks, { t1: ['x'], t2: ['y'] });
  assertEquals(counts.stale, 0);
});

// ------------------------------------------------------------------------------------------------
// Owner information kinds (customer_delivery, estimate_entered, rewash_added, off_queue_start) and
// account_locked. Payload shapes = app.alert_payload (20261107003625, 20261107120000).

const DELIVERY = '33333333-3333-3333-3333-333333333333';
// 2026-11-07 02:15 UTC = 9:15 PM on 11-06 in Miami (EST)
const delivery = {
  delivery_id: DELIVERY,
  customer_id: 'c1',
  customer_name: 'AA Linen',
  customer_name_i18n: {},
  delivered_at: '2026-11-07T02:15:00Z',
  voided: false,
  total_bins: 3.5,
  lines: [
    {
      wash_group_id: 'g1',
      wash_group_name: 'AA napkins',
      wash_group_name_i18n: { es: 'Servilletas AA' },
      bins: 2,
      loads: 4,
    },
    {
      wash_group_id: 'g2',
      wash_group_name: 'AA mats',
      wash_group_name_i18n: {},
      bins: 1,
      loads: null,
    },
    {
      wash_group_id: 'g3',
      wash_group_name: 'AA aprons',
      wash_group_name_i18n: {},
      bins: 0.5,
      loads: 1,
    },
  ],
};

Deno.test('customer_delivery: EN/ES text with bins per group, tag per delivery', () => {
  assertEquals(msg('customer_delivery', delivery, 'en'), {
    title: 'AA Linen delivered',
    body: '2 bins AA napkins, 1 bin AA mats, ½ bin AA aprons · at 9:15 PM',
    tag: `delivery-${DELIVERY}`,
    url: '/control/deliveries',
  });
  const es = msg('customer_delivery', delivery, 'es');
  assertEquals(es.title, 'Entrega de AA Linen');
  // ICU spells "p. m." differently across versions: compare up to the hour.
  assert(
    es.body.startsWith(
      '2 bins de Servilletas AA, 1 bin de AA mats, ½ bin de AA aprons · a las 9:15',
    ),
    es.body,
  );
});

Deno.test('customer_delivery: no names, notes or ids beyond the subject reach the text', () => {
  const m = msg(
    'customer_delivery',
    { ...delivery, note: 'secret note', entered_by_name: 'Denise' },
    'en',
  );
  assertFalse(JSON.stringify(m).includes('secret'));
  assertFalse(JSON.stringify(m).includes('Denise'));
});

Deno.test('customer_delivery: long lists are capped; bad lines skipped; voided is stale', () => {
  const many = {
    ...delivery,
    lines: Array.from({ length: 7 }, (_, i) => ({ wash_group_name: `G${i}`, bins: 0.25 })),
  };
  assertEquals(
    msg('customer_delivery', many, 'en').body,
    '¼ bin G0, ¼ bin G1, ¼ bin G2, ¼ bin G3 +3 more · at 9:15 PM',
  );
  assert(msg('customer_delivery', many, 'es').body.includes('+3 más'));
  const bad = {
    ...delivery,
    lines: [{ wash_group_name: 'X', bins: 'a lot' }, null, 7],
  };
  assertEquals(msg('customer_delivery', bad, 'en').body, 'At 9:15 PM');
  const unnamed = { ...delivery, customer_name: null };
  assertEquals(msg('customer_delivery', unnamed, 'en').title, 'Customer delivery');
  assertEquals(msg('customer_delivery', unnamed, 'es').title, 'Entrega de un cliente');
  assertEquals(buildMessage('customer_delivery', { ...delivery, delivery_id: null }, 'en'), null);
  assert(BUILDERS.customer_delivery.isCurrent(delivery));
  assertFalse(BUILDERS.customer_delivery.isCurrent({ ...delivery, voided: true }));
});

const estimates = {
  first_estimate_id: 'e1',
  count: 3,
  estimates: [
    {
      wash_group_name: 'Mats 3x5',
      wash_group_name_i18n: { es: 'Mapos 3x5' },
      qty: 2.5,
      unit: 'basket',
    },
    {
      wash_group_name: 'Napkins',
      wash_group_name_i18n: {},
      qty: 1,
      unit: 'bin',
    },
    {
      wash_group_name: 'Sheets',
      wash_group_name_i18n: {},
      qty: 0.75,
      unit: 'load',
    },
  ],
};

Deno.test('estimate_entered: EN/ES text, one tag per batch, never stale', () => {
  assertEquals(msg('estimate_entered', estimates, 'en'), {
    title: '3 new estimates',
    body: 'Mats 3x5 2½ baskets, Napkins 1 bin, Sheets ¾ load',
    tag: 'estimates-e1',
    url: '/control/estimates',
  });
  const es = msg('estimate_entered', estimates, 'es');
  assertEquals(es.title, '3 estimados nuevos');
  assertEquals(es.body, 'Mapos 3x5 2½ canastas, Napkins 1 bin, Sheets ¾ carga');
  const one = {
    first_estimate_id: 'e1',
    count: 1,
    estimates: [estimates.estimates[0]],
  };
  assertEquals(msg('estimate_entered', one, 'en').title, 'New estimate');
  assertEquals(msg('estimate_entered', one, 'es').title, 'Estimado nuevo');
  assertEquals(
    msg(
      'estimate_entered',
      {
        ...one,
        estimates: [{ wash_group_name: 'X', qty: 0, unit: 'load' }],
      },
      'en',
    ).body,
    'X 0 loads',
  );
  assertEquals(buildMessage('estimate_entered', { count: 1 }, 'en'), null);
  assert(BUILDERS.estimate_entered.isCurrent(estimates));
});

const rewash = {
  queue_item_id: 'q1',
  area_id: 'a1',
  area_name: 'Washroom',
  wash_group_name: 'Kitchen towels',
  wash_group_name_i18n: { es: 'Toallas de cocina' },
  qty: 1.5,
  unit: 'bin',
  qty_loads: 3,
  status: 'queued',
  created_at: '2026-11-07T02:15:00Z',
};

Deno.test('rewash_added: EN/ES text; cancelled is stale', () => {
  assertEquals(msg('rewash_added', rewash, 'en'), {
    title: 'Rewash added to the queue',
    body: 'Kitchen towels · 1½ bins',
    tag: 'rewash-q1',
    url: '/control/queue',
  });
  assertEquals(msg('rewash_added', rewash, 'es').title, 'Relavado agregado a la cola');
  assertEquals(msg('rewash_added', rewash, 'es').body, 'Toallas de cocina · 1½ bins');
  assertEquals(msg('rewash_added', { ...rewash, unit: 'pack' }, 'en').body, 'Kitchen towels');
  assertEquals(buildMessage('rewash_added', { ...rewash, queue_item_id: 7 }, 'en'), null);
  assert(BUILDERS.rewash_added.isCurrent(rewash));
  assert(BUILDERS.rewash_added.isCurrent({ ...rewash, status: 'in_progress' }));
  assertFalse(BUILDERS.rewash_added.isCurrent({ ...rewash, status: 'cancelled' }));
});

const offQueue = {
  cycle_id: 'w1',
  machine_id: 'm1',
  machine_name: 'Washer 3',
  area_name: 'Washroom',
  wash_group_name: 'Mats 3x5',
  wash_group_name_i18n: { es: 'Mapos 3x5' },
  is_rewash: false,
  started_at: '2026-11-07T02:15:00Z',
  queue_item_id: null,
  off_queue: true,
  expected_wash_group_id: 'g9',
  expected_wash_group_name: 'Napkins',
  expected_wash_group_name_i18n: { es: 'Servilletas' },
  voided: false,
};

Deno.test('off_queue_start: off the queue vs not the next, EN/ES; voided is stale', () => {
  assertEquals(msg('off_queue_start', offQueue, 'en'), {
    title: 'Washer 3: load not in the queue',
    body: 'Mats 3x5 · queue next: Napkins · at 9:15 PM',
    tag: 'off-queue-w1',
    url: '/control/washers',
  });
  const es = msg('off_queue_start', offQueue, 'es');
  assertEquals(es.title, 'Lavadora 3: carga fuera de la cola');
  assert(es.body.startsWith('Mapos 3x5 · próximo: Servilletas · a las 9:15'), es.body);
  const other = { ...offQueue, off_queue: false, queue_item_id: 'q1' };
  assertEquals(msg('off_queue_start', other, 'en').title, 'Washer 3: not the next in the queue');
  assertEquals(
    msg('off_queue_start', other, 'es').title,
    'Lavadora 3: no era lo próximo de la cola',
  );
  const nothing = {
    ...offQueue,
    expected_wash_group_name: null,
    expected_wash_group_name_i18n: null,
  };
  assertEquals(
    msg('off_queue_start', nothing, 'en').body,
    'Mats 3x5 · nothing queued · at 9:15 PM',
  );
  assertEquals(
    msg('off_queue_start', { ...offQueue, machine_name: '' }, 'en').title,
    'A washer: load not in the queue',
  );
  assertEquals(buildMessage('off_queue_start', { ...offQueue, cycle_id: null }, 'en'), null);
  assert(BUILDERS.off_queue_start.isCurrent(offQueue));
  assertFalse(BUILDERS.off_queue_start.isCurrent({ ...offQueue, voided: true }));
});

const locked = {
  user_id: 'u1',
  username: 'denise',
  failures: 5,
  locked_until: '2026-11-07T02:30:00Z',
  still_locked: true,
};

Deno.test('account_locked: username only, EN/ES, stale once unlocked', () => {
  assertEquals(msg('account_locked', locked, 'en'), {
    title: 'Account locked: denise',
    body: '5 wrong passwords · until 9:30 PM · Unlock in People',
    tag: 'locked-u1',
    url: '/control/people',
  });
  const es = msg('account_locked', locked, 'es');
  assertEquals(es.title, 'Cuenta bloqueada: denise');
  assert(es.body.startsWith('5 contraseñas incorrectas · hasta las 9:30'), es.body);
  assert(es.body.endsWith(' · Desbloquear en Personas'), es.body);
  assertEquals(
    msg('account_locked', { ...locked, username: null }, 'en').title,
    'Owner account locked',
  );
  assertEquals(buildMessage('account_locked', { ...locked, user_id: null }, 'en'), null);
  assertFalse(BUILDERS.account_locked.isCurrent({ ...locked, still_locked: false }));
});

Deno.test('every kind the DB can push has a builder', () => {
  // = app.push_alert_kinds() (20261107120000)
  for (const kind of [
    'machine_down',
    'washer_idle',
    'task_assigned',
    'task_done',
    'route_loaded',
    'customer_delivery',
    'estimate_entered',
    'rewash_added',
    'off_queue_start',
    'account_locked',
  ]) {
    assert(Object.hasOwn(BUILDERS, kind), kind);
  }
});

Deno.test('run: owner kinds are sent; stale ones are marked stale', async () => {
  const { deps, rec } = mockDeps(
    [
      row({
        alert_id: 'd1',
        kind: 'customer_delivery',
        payload: delivery,
        subscription_id: 'x',
      }),
      row({
        alert_id: 'd2',
        kind: 'customer_delivery',
        payload: { ...delivery, voided: true },
        subscription_id: 'y',
      }),
      row({
        alert_id: 'l1',
        kind: 'account_locked',
        payload: locked,
        subscription_id: 'z',
        language: 'es',
      }),
    ],
    () => 'ok',
  );
  const counts = await run(deps, NOW);
  assertEquals(rec.marks, { d1: ['x'], d2: ['stale'], l1: ['z'] });
  assertEquals(counts.sent, 2);
  assertEquals(counts.stale, 1);
  assertEquals(
    rec.sends.find((s) => s.payload.tag === 'locked-u1')?.payload.title,
    'Cuenta bloqueada: denise',
  );
});
