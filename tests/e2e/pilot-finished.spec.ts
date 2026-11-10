import { test, expect, type Page } from 'playwright/test';
import { execSync } from 'node:child_process';

// Finished goods entry (owner 2026-11-10). Local only; made-up local owner. Needs a CURRENT shift
// instance on the local finishing area (the seed's shift instances); skipped when there is none.
const OWNER = {
  user: process.env.E2E_OWNER_EMAIL ?? 'owner@example.test',
  pass: process.env.E2E_OWNER_PASSWORD ?? 'local-test-owner-1',
};
const SHOTS = process.env.SHOTS_DIR ?? 'test-results/shots';
const sql = (q: string) =>
  execSync(
    `docker exec -i supabase_db_plantboard psql -U postgres -tA -c "${q.replace(/"/g, '\\"')}"`,
  )
    .toString()
    .trim();

async function ownerSignIn(page: Page) {
  await page.context().clearCookies();
  await page.goto('/sign-in');
  await page.evaluate(() => {
    try {
      localStorage.clear();
      sessionStorage.clear();
    } catch {
      /* */
    }
  });
  await page.reload();
  await page.getByLabel('Username').fill(OWNER.user);
  await page.locator('#password').fill(OWNER.pass);
  await page.getByRole('button', { name: 'Sign in', exact: true }).click();
  await page.waitForURL(/\/control/);
}

const SHEET_COUNT = `select count(*) from public.finished_goods_entries f join public.item_types i on i.id = f.item_type_id where i.name = 'Sheet – regular' and f.voided_at is null`;

test.use({ viewport: { width: 1024, height: 768 } });

test('owner adds +1 bin of Sheet – regular, sees the total and Undo', async ({ page }) => {
  const current = sql(
    `select count(*) from public.areas a where a.kind = 'finishing' and app.shift_instance_at(a.id, now()) is not null`,
  );
  test.skip(current !== '1', 'the local finishing area has no current shift instance');
  const before = Number(sql(SHEET_COUNT));

  await ownerSignIn(page);
  await page.goto('/control/finished');
  await expect(page.getByRole('heading', { name: 'Finished goods', level: 1 })).toBeVisible();
  await expect(page.getByRole('button', { name: 'End of shift review' })).toBeVisible();

  // Nothing pinned yet: the picker is open. Sheets chip, then the item.
  await page.getByRole('button', { name: 'Sheets', exact: true }).click();
  await page.getByRole('button', { name: /^Sheet – regular/ }).click();
  await expect(page.getByRole('heading', { name: 'Sheet – regular', exact: true })).toBeVisible();

  await page.getByRole('button', { name: '+1 bin (500)' }).click();
  const toast = page.locator('.fg-toast');
  await expect(toast).toContainText('+500 Sheet – regular · shift total');
  await expect(page.getByRole('button', { name: 'Undo', exact: true })).toBeVisible();
  await expect.poll(() => Number(sql(SHEET_COUNT))).toBe(before + 1);
  await page.screenshot({ path: `${SHOTS}/finished-1024.png`, fullPage: true });

  // The same tap again within 5 s asks first.
  await page.getByRole('button', { name: '+1 bin (500)' }).click();
  await expect(page.getByRole('heading', { name: 'Add another 500?' })).toBeVisible();
  await page.getByRole('button', { name: "Don't save" }).click();
  expect(Number(sql(SHEET_COUNT))).toBe(before + 1);

  // Undo voids the line on the server.
  await page.getByRole('button', { name: 'Undo', exact: true }).click();
  await expect(toast).toContainText('Undone');
  await expect.poll(() => Number(sql(SHEET_COUNT))).toBe(before);

  // Add it back for the phone screenshot, then the review.
  await page.getByRole('button', { name: '+1 bin (500)' }).click();
  await expect.poll(() => Number(sql(SHEET_COUNT))).toBe(before + 1);
  await page.setViewportSize({ width: 390, height: 844 });
  await page.screenshot({ path: `${SHOTS}/finished-390.png`, fullPage: true });
  await page.getByRole('button', { name: 'End of shift review' }).click();
  await expect(page.getByRole('heading', { name: 'End of shift review', level: 2 })).toBeVisible();
  await expect(page.locator('.fg-review-row', { hasText: 'Sheet – regular' })).toBeVisible();
  await page.screenshot({ path: `${SHOTS}/finished-review-390.png`, fullPage: true });
});

const OLD_COUNT = `select count(*) from public.finished_goods_entries f join public.item_types i on i.id = f.item_type_id where i.name = 'Sheet – old' and f.voided_at is null`;

// Owner 2026-11-10: old sheets go into ONE fixed bin they keep adding to: "Sheets done…" (a count of
// pieces, pre-filled with the last count on this device), no packs, no "Leftover…".
test('owner adds old sheets with Sheets done…', async ({ page }) => {
  const current = sql(
    `select count(*) from public.areas a where a.kind = 'finishing' and app.shift_instance_at(a.id, now()) is not null`,
  );
  test.skip(current !== '1', 'the local finishing area has no current shift instance');
  const before = Number(sql(OLD_COUNT));

  await ownerSignIn(page);
  await page.goto('/control/finished');
  await page.getByRole('button', { name: 'Sheets', exact: true }).click();
  await page.getByRole('button', { name: /^Sheet – old/ }).click();
  await expect(page.getByRole('heading', { name: 'Sheet – old', exact: true })).toBeVisible();
  await expect(page.getByRole('button', { name: 'Leftover…' })).toHaveCount(0);
  await expect(page.getByRole('button', { name: /^\+1 pack/ })).toHaveCount(0);

  await page.getByRole('button', { name: 'Sheets done…' }).click();
  await page.getByLabel('How many old sheets did you finish?').fill('500');
  await page.getByRole('button', { name: 'Add', exact: true }).click();
  await expect(page.locator('.fg-toast')).toContainText('+500 Sheet – old');
  await expect.poll(() => Number(sql(OLD_COUNT))).toBe(before + 1);

  // The next time, the count is pre-filled with the last one used on this device.
  await page.getByRole('button', { name: 'Sheets done…' }).click();
  await expect(page.getByLabel('How many old sheets did you finish?')).toHaveValue('500');
  await page.getByRole('button', { name: 'Cancel', exact: true }).click();

  // Leave local data as it was.
  await page.getByRole('button', { name: 'Undo', exact: true }).click();
  await expect.poll(() => Number(sql(OLD_COUNT))).toBe(before);
});

test('owner sets a stock count in Setup → Items', async ({ page }) => {
  await ownerSignIn(page);
  await page.goto('/control/setup/items');
  await expect(page.getByRole('heading', { name: 'Setup: items', level: 1 })).toBeVisible();
  await expect(page.getByRole('heading', { name: 'Linens', level: 2 })).toBeVisible();
  await page.getByRole('button', { name: 'Edit Napkin – Navy Blue', exact: true }).click();
  await page.getByLabel('How many the plant owns (optional)').fill('10000');
  await page.getByRole('button', { name: 'Black', exact: true }).click();
  await page.getByRole('button', { name: 'Save', exact: true }).click();
  await expect(page.getByText('Napkin – Navy Blue saved.')).toBeVisible();
  expect(
    sql(
      `select stock_qty || ' ' || color_hex from public.item_types where name = 'Napkin – Navy Blue'`,
    ),
  ).toBe('10000 #000000');
  await page.screenshot({ path: `${SHOTS}/setup-items-1024.png` });
  // Put the seed colour back (local data only).
  sql(
    `update public.item_types set stock_qty = null, color_hex = '#1E3A8A' where name = 'Napkin – Navy Blue'`,
  );
});
