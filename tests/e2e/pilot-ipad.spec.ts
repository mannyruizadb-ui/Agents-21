import { test, expect, type Page } from 'playwright/test';

// Shared plant iPad (owner 2026-11-10). Runs after pilot-auth.spec.ts (denise exists with 730514).
// Local only; made-up local owner.
const OWNER = {
  user: process.env.E2E_OWNER_EMAIL ?? 'owner@example.test',
  pass: process.env.E2E_OWNER_PASSWORD ?? 'local-test-owner-1',
};
const DENISE_PASS = '730514';
const SHOTS = process.env.SHOTS_DIR ?? 'test-results/shots';

test.use({ viewport: { width: 1024, height: 768 } });

async function ownerSignIn(page: Page) {
  await page.getByLabel('Username').fill(OWNER.user);
  await page.locator('#password').fill(OWNER.pass);
  await page.getByRole('button', { name: 'Sign in', exact: true }).click();
  await page.waitForURL(/\/control/);
}

test('plant iPad: names + 6 digits, idle sign-out, owner removes it', async ({ page }) => {
  await page.goto('/sign-in');
  await page.evaluate(() => {
    localStorage.clear();
    sessionStorage.clear();
  });
  await page.reload();
  await ownerSignIn(page);

  // The owner marks this device.
  await page.goto('/control/setup/plant-ipad');
  await page.getByRole('button', { name: 'Make this the plant iPad' }).click();
  await expect(page.getByText('This device is the plant iPad (Plant iPad).')).toBeVisible();
  await page.screenshot({ path: `${SHOTS}/ipad-setup.png` });

  // "Switch person" signs out to the name list. The owner is never on it.
  await page.goto('/control/more');
  await page.getByRole('button', { name: 'Switch person' }).click();
  await expect(page.getByRole('heading', { name: "Who's signing in?" })).toBeVisible();
  const names = page.locator('.device-people button');
  await expect(names.first()).toBeVisible();
  expect(await names.allInnerTexts()).not.toContain('Manny Ruiz');
  await page.screenshot({ path: `${SHOTS}/ipad-names.png` });

  // Denise: a wrong password, then her own.
  await page.locator('.device-people button', { hasText: /denise/i }).click();
  await page.getByLabel('Your 6-digit password').fill('000000');
  await page.getByRole('button', { name: 'Sign in', exact: true }).click();
  await expect(page.getByText('Wrong password. Try again.')).toBeVisible();
  await page.getByLabel('Your 6-digit password').fill(DENISE_PASS);
  await page.getByRole('button', { name: 'Sign in', exact: true }).click();
  await page.waitForURL(/\/control/);

  // 11 minutes without use (the iPad slept): the next look signs her out.
  await page.evaluate(() =>
    localStorage.setItem('plantboard.sharedDevice.lastActive', String(Date.now() - 11 * 60_000)),
  );
  await page.reload();
  await expect(page.getByText('Signed out after 10 minutes without use.')).toBeVisible();
  await page.screenshot({ path: `${SHOTS}/ipad-idle.png` });

  // The owner signs in the normal way and removes this device: back to the normal sign-in.
  await page.getByRole('button', { name: 'Sign in another way' }).click();
  await ownerSignIn(page);
  await page.goto('/control/setup/plant-ipad');
  await page.getByRole('button', { name: 'Stop using this device as the plant iPad' }).click();
  await expect(
    page.getByText('Removed. That device goes back to the normal sign-in.'),
  ).toBeVisible();
  await page.goto('/control/more');
  await page.getByRole('button', { name: 'Sign out' }).click();
  await expect(page.getByRole('heading', { name: 'Sign in' })).toBeVisible();
  await expect(page.locator('.device-people')).toHaveCount(0);
});
