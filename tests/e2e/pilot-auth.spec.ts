import { test, expect, type Page } from 'playwright/test';
import { execSync } from 'node:child_process';

// Local-only pilot checks: legacy owner upgrade, People create, forced change, lockout + unlock.
// Prereq: a LOCAL owner (E2E_OWNER_EMAIL / E2E_OWNER_PASSWORD, made-up values) seeded without app_metadata.pw_v.
// Local test owner only: never a real account or password.
const OWNER = {
  user: process.env.E2E_OWNER_EMAIL ?? 'owner@example.test',
  pass: process.env.E2E_OWNER_PASSWORD ?? 'local-test-owner-1',
};
const DENISE = { user: 'denise', start: '482913', next: '730514' };
const SHOTS = process.env.SHOTS_DIR ?? 'test-results/shots';

const sql = (q: string) =>
  execSync(
    `docker exec -i supabase_db_plantboard psql -U postgres -tA -c "${q.replace(/"/g, '\\"')}"`,
  )
    .toString()
    .trim();

async function signIn(page: Page, user: string, pass: string) {
  await page.goto('/sign-in');
  await page.getByLabel('Username').fill(user);
  await page.locator('#password').fill(pass);
  await page.getByRole('button', { name: 'Sign in', exact: true }).click();
}
async function signOut(page: Page) {
  await page.evaluate(() => {
    try {
      localStorage.clear();
      sessionStorage.clear();
    } catch {
      /* */
    }
  });
  await page.context().clearCookies();
}

test.describe.serial('pilot auth', () => {
  test('sign-in screenshots 390 and 1024', async ({ page }) => {
    await page.goto('/sign-in');
    await expect(page.getByRole('heading', { level: 1 })).toBeVisible();
    await page.screenshot({ path: `${SHOTS}/signin-390.png` });
    await page.setViewportSize({ width: 1024, height: 768 });
    await page.screenshot({ path: `${SHOTS}/signin-1024.png` });
  });

  test('1a owner legacy upgrade then peppered sign-in', async ({ page }) => {
    expect(
      sql(
        `select coalesce(raw_app_meta_data->>'pw_v','none') from auth.users where email='${OWNER.user}'`,
      ),
    ).toBe('none');
    await signIn(page, OWNER.user, OWNER.pass);
    // Bug B1 (fixed 2026-11-07): the upgrade used to end the session it returned. The FIRST sign-in
    // with a pre-pepper password must land on /control.
    await page.waitForURL(/\/control/, { timeout: 8000 });
    expect(
      sql(`select raw_app_meta_data->>'pw_v' from auth.users where email='${OWNER.user}'`),
    ).toBe('2');
    await signOut(page);
    await signIn(page, OWNER.user, OWNER.pass);
    await page.waitForURL(/\/control/);
    expect(page.url()).not.toContain('change-password');
  });

  test('2 owner creates denise with chosen 6-digit password', async ({ page }) => {
    await signIn(page, OWNER.user, OWNER.pass);
    await page.waitForURL(/\/control/);
    await page.goto('/control/people');
    await page.getByLabel('Name', { exact: true }).fill('Denise');
    await page.getByLabel('Username', { exact: true }).fill(DENISE.user);
    await page.getByLabel('Starting password (optional)').fill(DENISE.start);
    await page.getByRole('button', { name: 'Create account' }).click();
    await expect(page.getByText(/denise/i).first()).toBeVisible();
    await page.screenshot({ path: `${SHOTS}/people-created.png`, fullPage: true });
    expect(
      sql(
        `select coalesce(raw_app_meta_data->>'must_change_password','x')||'/'||coalesce(raw_app_meta_data->>'pw_v','x') from auth.users where email like 'denise@%'`,
      ),
    ).toBe('false/2'); // owner 2026-11-10: no forced change
  });

  test('2b denise keeps the password the owner gave; changing it later never freezes', async ({
    page,
  }) => {
    // Owner 2026-11-10: no forced change on first sign-in.
    await signIn(page, DENISE.user, DENISE.start);
    await page.waitForURL(/\/control/);
    await expect(page.getByRole('heading', { name: 'Choose a new password' })).toHaveCount(0);
    expect(
      sql(
        `select coalesce(raw_app_meta_data->>'must_change_password','false') from auth.users where email like 'denise@%'`,
      ),
    ).toBe('false');
    // A voluntary change (More → Change my password) signs her straight back in: no stuck page.
    await page.goto('/control/password');
    await page.getByLabel('Current password').fill(DENISE.start);
    await page.getByLabel('New password', { exact: true }).fill(DENISE.next);
    await page.getByLabel('Type it again').fill(DENISE.next);
    await page.getByRole('button', { name: 'Save password' }).click();
    await expect(page.getByText('Password changed.')).toBeVisible();
    await page.goto('/control');
    await expect(page).toHaveURL(/\/control$/);
    await signOut(page);
    await signIn(page, DENISE.user, DENISE.next);
    await page.waitForURL(/\/control/);
  });

  test('3 five wrong passwords lock; owner unlocks', async ({ page }) => {
    await signOut(page);
    for (let i = 0; i < 5; i++) {
      await signIn(page, DENISE.user, '111111');
      await expect(page.getByRole('status').filter({ hasText: /./ }).first()).toBeVisible();
    }
    await signIn(page, DENISE.user, DENISE.next);
    await expect(page.getByText(/Too many wrong tries/)).toBeVisible();
    await page.screenshot({ path: `${SHOTS}/locked.png` });
    await signOut(page);
    await signIn(page, OWNER.user, OWNER.pass);
    await page.waitForURL(/\/control/);
    await page.goto('/control/people');
    await expect(page.getByRole('group', { name: 'Sign-in locked' })).toBeVisible();
    await page.getByRole('button', { name: 'Unlock' }).click();
    await expect(page.getByText(/can sign in again/)).toBeVisible();
    await signOut(page);
    await signIn(page, DENISE.user, DENISE.next);
    await page.waitForURL(/\/control/);
  });
});
