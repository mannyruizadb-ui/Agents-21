import { test, expect, type Page } from 'playwright/test';
import { execSync } from 'node:child_process';

// Runs after pilot-auth.spec.ts (denise exists, owner upgraded). Local only.
const OWNER = { user: 'mannyruiz.adb@gmail.com', pass: 'OwnerPass-2026' };
const DENISE = { user: 'denise', pass: '730514' };
const SHOTS = process.env.SHOTS_DIR ?? '/tmp/claude-0/-home-user-Agents-21/e78dd717-40be-5a1d-ae72-3689e13533cc/scratchpad/shots';
const sql = (q: string) =>
  execSync(`docker exec -i supabase_db_plantboard psql -U postgres -tA -c "${q.replace(/"/g, '\\"')}"`).toString().trim();

async function signIn(page: Page, user: string, pass: string) {
  await page.goto('/sign-in');
  await page.getByLabel('Username').fill(user);
  await page.locator('#password').fill(pass);
  await page.getByRole('button', { name: 'Sign in', exact: true }).click();
  await page.waitForURL(/\/control/);
}
const fresh = async (page: Page) => {
  await page.context().clearCookies();
  await page.goto('/sign-in');
  await page.evaluate(() => { try { localStorage.clear(); sessionStorage.clear(); } catch { /* */ } });
};

test.describe.serial('pilot ops', () => {
  test('4a denise saves an estimate with no PIN prompt', async ({ page }) => {
    await fresh(page);
    await signIn(page, DENISE.user, DENISE.pass);
    await page.goto('/control/estimates');
    await page.getByRole('button', { name: 'Nothing waiting' }).first().click();
    await page.getByRole('button', { name: /^Review/ }).click();
    expect(await page.getByText(/\bPIN\b/).count()).toBe(0);
    await page.getByRole('button', { name: /^Save \d+ estimate/ }).click();
    await expect(page.getByRole('heading', { level: 1 })).toBeVisible();
    await expect.poll(() => sql(`select count(*) from public.soil_estimates`)).toBe('1');
    await page.screenshot({ path: `${SHOTS}/estimate-saved.png` });
  });

  test('4b denise records an AA Linen delivery (no PIN), queue shows AA at bottom', async ({ page }) => {
    await fresh(page);
    await signIn(page, DENISE.user, DENISE.pass);
    await page.goto('/control/deliveries/new');
    const aa = page.getByRole('radio', { name: /AA/i });
    if (await aa.count()) await aa.first().click();
    const inputs = page.locator('input[id^="dl-bins-"]');
    await expect(inputs.first()).toBeVisible();
    await inputs.nth(0).fill('2');
    await inputs.nth(1).fill('1.5');
    expect(await page.getByText(/\bPIN\b/).count()).toBe(0);
    await page.getByRole('button', { name: 'Save delivery' }).click();
    await expect(page.getByText('Sent to the bottom of the queue.')).toBeVisible();
    await page.screenshot({ path: `${SHOTS}/delivery-saved.png` });
    expect(sql(`select count(*) from public.queue_items where status<>'cancelled' and customer_id is not null`)).toBe('2');
    await page.goto('/control/queue');
    const items = page.locator('main li');
    await expect(page.getByText('AA', { exact: false }).first()).toBeVisible();
    await page.screenshot({ path: `${SHOTS}/queue-aa.png`, fullPage: true });
    // AA items are the last rows by position
    expect(sql(`select string_agg((customer_id is not null)::text, ',' order by position) from public.queue_items where status<>'cancelled'`)).toMatch(/(^|,)true,true$/);
    void items;
    // 4c: cancel from the same phone (manager cancel list is per-device; history screen is owner-only)
    await page.goto('/control/deliveries/new');
    await page.getByRole('button', { name: 'Cancel this delivery' }).first().click();
    await page.getByLabel('Reason').fill('Wrong count');
    await page.getByRole('button', { name: 'Yes, cancel it' }).click();
    await expect(page.getByText('Delivery cancelled.')).toBeVisible();
    expect(sql(`select count(*) from public.queue_items where status='cancelled'`)).toBe('2');
    expect(sql(`select count(*) from public.customer_deliveries where voided_at is not null`)).toBe('1');
    await page.screenshot({ path: `${SHOTS}/delivery-cancelled.png`, fullPage: true });
  });

  test('5 owner Alerts tab cards and alert-level controls', async ({ page }) => {
    await fresh(page);
    await signIn(page, OWNER.user, OWNER.pass);
    await page.goto('/control/alerts');
    await expect(page.getByText(/delivered/i).first()).toBeVisible();
    await expect(page.getByText(/Estimates entered/i).first()).toBeVisible();
    await expect(page.getByText(/Account locked/i).first()).toBeVisible();
    await page.screenshot({ path: `${SHOTS}/alerts-owner.png`, fullPage: true });
    await page.goto('/control/people');
    const cards = page.locator('li.person-card');
    await expect(cards).toHaveCount(2);
    const n = await cards.count();
    const levelCounts: Record<string, number> = {};
    for (let i = 0; i < n; i++) {
      const name = (await cards.nth(i).locator('h3').innerText()).trim();
      levelCounts[name] = await cards.nth(i).locator('select, [role="radiogroup"], input[type="radio"]').count();
    }
    test.info().annotations.push({ type: 'alert-level-controls', description: JSON.stringify(levelCounts) });
    await page.screenshot({ path: `${SHOTS}/people-levels.png`, fullPage: true });
    const own = Object.entries(levelCounts).find(([k]) => /Manny/.test(k));
    expect(own && own[1] > 0, 'owner row has alert-level controls').toBeTruthy();
    for (const [k, v] of Object.entries(levelCounts)) if (!/Manny/.test(k)) expect(v, `${k} row has none`).toBe(0);
  });

  test('6 Back button on a deeper screen; tablet screenshot', async ({ page }) => {
    await fresh(page);
    await signIn(page, OWNER.user, OWNER.pass);
    await page.goto('/control/deliveries/new');
    await expect(page.getByRole('button', { name: /^Back$/ }).or(page.getByRole('link', { name: /^Back$/ })).first()).toBeVisible();
    await page.screenshot({ path: `${SHOTS}/deeper-back.png` });
  });
});
