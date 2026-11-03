import { describe, expect, it } from 'vitest';
import * as app from './loginId';
// The Edge Function keeps its own copy (it cannot import from src/). Same cases, both copies.
import * as edge from '../../supabase/functions/_shared/loginId';

describe.each([
  ['src/lib/loginId', app],
  ['supabase/functions/_shared/loginId', edge],
])('%s', (_name, m) => {
  it('maps a username to the no-mailbox accounts domain', () => {
    expect(m.toLoginEmail('maria')).toBe('maria@accounts.adbheadquarters.com');
    expect(m.toLoginEmail('j.ruiz_2-b')).toBe('j.ruiz_2-b@accounts.adbheadquarters.com');
  });

  it('trims and lowercases what was typed', () => {
    expect(m.toLoginEmail('  Maria ')).toBe('maria@accounts.adbheadquarters.com');
  });

  it('uses a value with @ as-is (lowercased)', () => {
    expect(m.toLoginEmail('Owner@Example.com')).toBe('owner@example.com');
  });

  it("owner's real-email account: the full email typed into the Username field signs in", () => {
    // The owner's dashboard-created account uses a real email (placeholder address here).
    for (const typed of ['owner.name@example.com', ' Owner.Name@Example.COM ']) {
      expect(m.toLoginEmail(typed)).toBe('owner.name@example.com');
    }
    // It is never mapped to the accounts domain, and never turned into a username for display.
    expect(m.usernameFromEmail('owner.name@example.com')).toBeNull();
  });

  it('rejects usernames that break the rule', () => {
    for (const bad of ['', 'ab', 'a'.repeat(33), 'josé', 'jo hn', 'a+b', 'a/b']) {
      expect(m.toLoginEmail(bad)).toBeNull();
      expect(m.isValidUsername(bad)).toBe(false);
    }
  });

  it('accepts the length bounds', () => {
    expect(m.isValidUsername('abc')).toBe(true);
    expect(m.isValidUsername('a'.repeat(32))).toBe(true);
  });

  it('isValidUsername does not lowercase (the stored form must already be lowercase)', () => {
    expect(m.isValidUsername('Maria')).toBe(false);
  });

  it('turns a mapped email back into the username; any other email gives null (never shown)', () => {
    expect(m.usernameFromEmail('maria@accounts.adbheadquarters.com')).toBe('maria');
    expect(m.usernameFromEmail('Maria@Accounts.ADBheadquarters.com')).toBe('maria');
    expect(m.usernameFromEmail('owner@example.com')).toBeNull();
    expect(m.usernameFromEmail('a@accounts.adbheadquarters.com')).toBeNull();
    expect(m.usernameFromEmail('x@evil.accounts.adbheadquarters.com.example')).toBeNull();
  });

  it('owner account created in the dashboard as <username>@accounts… signs in by username', () => {
    // The owner types only the username (any case, stray spaces), exactly like everyone else.
    const dashboardEmail = 'manny@accounts.adbheadquarters.com';
    for (const typed of ['manny', 'Manny', '  MANNY  ']) {
      expect(m.toLoginEmail(typed)).toBe(dashboardEmail);
    }
    expect(m.usernameFromEmail(dashboardEmail)).toBe('manny');
  });
});

it('both copies use the same domain and pattern', () => {
  expect(edge.LOGIN_EMAIL_DOMAIN).toBe(app.LOGIN_EMAIL_DOMAIN);
  expect(edge.USERNAME_PATTERN.source).toBe(app.USERNAME_PATTERN.source);
});
