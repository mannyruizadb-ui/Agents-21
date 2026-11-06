import { describe, expect, it } from 'vitest';
import { memoryStore } from '../../lib/scopedStore';
import { newTap, type RejectedTap } from './tapQueue';
import { ackAlarm, readAcked, STUCK_AFTER_MS, tapAlarms } from './tapAlarms';

const NOW = Date.parse('2026-11-05T20:00:00Z');
const at = (msAgo: number) => new Date(NOW - msAgo);
const rejected = (id: string, code: string): RejectedTap => ({
  ...newTap('w4', null, id, at(40 * 60000)),
  errorCode: code,
  rejectedAt: new Date(NOW).toISOString(),
});

describe('tapAlarms', () => {
  it('alarms a tap the server refused as too late, not other refusals', () => {
    const a = tapAlarms(
      [],
      [rejected('late', 'OUT_OF_RANGE_TIMESTAMP'), rejected('down', 'MACHINE_DOWN')],
      new Set(),
      NOW,
    );
    expect(a.map((x) => [x.clientId, x.kind])).toEqual([['late', 'late']]);
  });
  it('alarms a tap waiting unsent for more than 20 minutes', () => {
    const pending = [
      newTap('w1', null, 'fresh', at(5 * 60000)),
      newTap('w2', null, 'old', at(STUCK_AFTER_MS + 60000)),
    ];
    const a = tapAlarms(pending, [], new Set(), NOW);
    expect(a).toEqual([
      {
        clientId: 'old',
        machineId: 'w2',
        tappedAt: at(STUCK_AFTER_MS + 60000).toISOString(),
        kind: 'stuck',
        waitingMinutes: 21,
      },
    ]);
  });
  it('dismissed alarms stay hidden, but the taps themselves are untouched', () => {
    const s = memoryStore();
    const pending = [newTap('w2', null, 'old', at(STUCK_AFTER_MS + 60000))];
    ackAlarm(s, 'old', ['old']);
    expect(tapAlarms(pending, [], readAcked(s), NOW)).toEqual([]);
    expect(pending).toHaveLength(1);
  });
  it('prunes acknowledgements of taps that are gone', () => {
    const s = memoryStore();
    ackAlarm(s, 'a', ['a']);
    ackAlarm(s, 'b', ['b']); // 'a' no longer exists
    expect([...readAcked(s)]).toEqual(['b']);
  });
});
