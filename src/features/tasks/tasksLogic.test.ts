import { describe, expect, it } from 'vitest';
import { cleanTaskText, isNobodyOnDuty, minutesBetween } from './tasksLogic';

describe('tasks logic', () => {
  it('cleans task text and enforces 1–200 characters', () => {
    expect(cleanTaskText('  check  all\nparked trucks ')).toBe('check all parked trucks');
    expect(cleanTaskText('   ')).toBeNull();
    expect(cleanTaskText('x'.repeat(201))).toBeNull();
    expect(cleanTaskText('x'.repeat(200))).toHaveLength(200);
  });
  it('measures how long a task has been open', () => {
    expect(minutesBetween('2026-11-06T10:00:00Z', Date.parse('2026-11-06T10:25:30Z'))).toBe(25);
    expect(minutesBetween('2026-11-06T10:00:00Z', Date.parse('2026-11-06T09:00:00Z'))).toBe(0);
    expect(minutesBetween('nope', 0)).toBe(0);
  });
  it("recognizes the server's nobody-on-duty refusal", () => {
    expect(isNobodyOnDuty('no manager is on duty now: choose a manager by name')).toBe(true);
    expect(isNobodyOnDuty('body: 1–200 characters')).toBe(false);
    expect(isNobodyOnDuty(null)).toBe(false);
  });
});
