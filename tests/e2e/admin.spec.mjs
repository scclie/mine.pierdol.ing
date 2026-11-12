import { test, expect } from '@playwright/test';
import { accountApi } from '../support/account-api.mjs';

async function openCard(page) {
  await page.goto('/admin/applications');
  await page.getByRole('button', { name: 'review Subject_Name', exact: true }).click();
  await expect(page.getByRole('heading', { name: 'Subject_Name', exact: true })).toBeVisible();
}

test('moderator sees pending queue and decision controls but no identity editor', async ({ page }, info) => {
  await accountApi(page, { role: 'moderator' });
  await openCard(page);
  await expect(page.getByLabel('status filter', { exact: true })).toHaveValue('pending');
  await expect(page.getByRole('button', { name: 'approve', exact: true })).toBeVisible();
  await expect(page.getByRole('form', { name: 'identity and status' })).toHaveCount(0);
  await expect(page.getByText('I build <b>railways</b>.', { exact: true })).toBeVisible();
  await expect(page.locator('main b')).toHaveCount(0);
  for (const name of ['reject — allow resubmission', 'reject — final']) {
    await expect(page.getByRole('button', { name, exact: true })).toBeDisabled();
  }
  await page.getByLabel('rejection reason', { exact: true }).fill('  \n ');
  for (const name of ['reject — allow resubmission', 'reject — final']) await expect(page.getByRole('button', { name, exact: true })).toBeDisabled();
  await page.getByLabel('rejection reason', { exact: true }).fill('Please add more detail.');
  for (const name of ['reject — allow resubmission', 'reject — final']) await expect(page.getByRole('button', { name, exact: true })).toBeEnabled();
  await page.screenshot({ path: info.outputPath('moderator.png'), fullPage: true });
  await page.setViewportSize({ width: 320, height: 844 });
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
});

for (const [name, status, body, suffix] of [
  ['approve', 'approved', {}, 'approve'],
  ['reject — allow resubmission', 'rejected_retryable', { kind: 'retryable', reason: 'Needs detail' }, 'reject'],
  ['reject — final', 'rejected_final', { kind: 'final', reason: 'Needs detail' }, 'reject'],
]) {
  test(`${name} confirms target and status, cancel sends nothing`, async ({ page }) => {
    const api = await accountApi(page, { role: 'moderator' });
    await openCard(page);
    await page.getByLabel('rejection reason', { exact: true }).fill('Needs detail');
    page.once('dialog', async (dialog) => { expect(dialog.message()).toContain('Subject_Name'); expect(dialog.message()).toContain(status); await dialog.dismiss(); });
    await page.getByRole('button', { name, exact: true }).click();
    expect(api.mutations).toHaveLength(0);
    page.once('dialog', async (dialog) => { expect(dialog.message()).toContain('Subject_Name'); expect(dialog.message()).toContain(status); await dialog.accept(); });
    await page.getByRole('button', { name, exact: true }).click();
    await expect(page.getByRole('status')).toHaveText('changes saved');
    expect(api.mutations[0].path).toBe(`/api/v1/admin/applications/2/${suffix}`);
    expect(api.mutations[0].body).toEqual(body);
    await expect(page.getByRole('button', { name: 'approve', exact: true })).toHaveCount(0);
  });
}

test('administrator edits identity and confirms new status, then can mutate with refreshed token', async ({ page }, info) => {
  const api = await accountApi(page, { role: 'administrator' });
  await openCard(page);
  const form = page.getByRole('form', { name: 'identity and status' });
  await expect(form).toBeVisible();
  await expect(form.getByLabel('discord id', { exact: true })).toHaveValue('423456789012345678');
  await expect(form.getByLabel('minecraft nickname', { exact: true })).toHaveValue('Subject_Name');
  await form.getByLabel('new status', { exact: true }).selectOption('banned');
  await form.getByLabel('change reason', { exact: true }).fill('Rule violations');
  await page.screenshot({ path: info.outputPath('admin.png'), fullPage: true });
  page.once('dialog', async (dialog) => { expect(dialog.message()).toContain('Subject_Name'); expect(dialog.message()).toContain('banned'); await dialog.accept(); });
  await form.getByRole('button', { name: 'save changes', exact: true }).click();
  await expect(page.getByRole('status')).toHaveText('changes saved');
  expect(api.mutations[0].body).toEqual({ status: 'banned', reason: 'Rule violations' });
  await form.getByLabel('minecraft nickname', { exact: true }).fill('NewName');
  await form.getByRole('button', { name: 'save changes', exact: true }).click();
  await expect(page.getByRole('heading', { name: 'NewName', exact: true })).toBeVisible();
  expect(api.mutations[1].body).toEqual({ minecraft_nickname: 'NewName' });
  expect(api.mutations[0].headers['x-csrf-token']).not.toBe(api.mutations[1].headers['x-csrf-token']);
  await page.setViewportSize({ width: 320, height: 844 });
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
});

test('server-side filter and pagination retain filters and reset cursor', async ({ page }) => {
  const api = await accountApi(page, { role: 'moderator', paginated: true });
  await page.goto('/admin/applications');
  await expect(page.getByRole('button', { name: 'next page', exact: true })).toBeEnabled();
  expect(api.queries[0]).toBe('?status=pending&limit=25');
  await page.getByLabel('status filter', { exact: true }).selectOption('banned');
  await page.getByLabel('search', { exact: true }).fill('Some Name');
  await page.getByLabel('page size', { exact: true }).selectOption('10');
  await page.getByRole('button', { name: 'filter', exact: true }).click();
  await expect.poll(() => api.queries.length).toBe(2);
  expect(api.queries[1]).toBe('?status=banned&limit=10&query=Some+Name');
  await page.getByRole('button', { name: 'next page', exact: true }).click();
  await expect(page.getByRole('button', { name: 'next page', exact: true })).toBeDisabled();
  expect(api.queries[2]).toBe('?status=banned&limit=10&query=Some+Name&cursor=00000000000000000000000000000002');
  await page.getByLabel('search', { exact: true }).fill('   ');
  await page.getByRole('button', { name: 'filter', exact: true }).click();
  await expect.poll(() => api.queries.length).toBe(4);
  expect(api.queries[3]).toBe('?status=banned&limit=10');
});

for (const role of ['player', 'unknown']) {
  test(`${role} cannot see moderation controls or fetch queue`, async ({ page }) => {
    const api = await accountApi(page, { role });
    await page.goto('/admin/applications');
    await expect(page.getByRole('alert')).toContainText('moderator or administrator');
    await expect(page.locator('main form:visible, main button:visible')).toHaveCount(0);
    expect(api.queries).toHaveLength(0);
  });
}

test('API authorization failure is visible after a confirmed decision', async ({ page }) => {
  await accountApi(page, { role: 'moderator', failure: 'insufficient_role', failureStatus: 403 });
  await openCard(page);
  page.once('dialog', (dialog) => dialog.accept());
  await page.getByRole('button', { name: 'approve', exact: true }).click();
  await expect(page.getByRole('alert')).toContainText('insufficient role');
  await expect(page.getByRole('status')).not.toHaveText('changes saved');
});

test('empty queue is explicit', async ({ page }) => {
  await accountApi(page, { role: 'moderator', empty: true });
  await page.goto('/admin/applications');
  await expect(page.getByText('no applications found', { exact: true })).toBeVisible();
  await expect(page.getByRole('button', { name: 'next page', exact: true })).toBeDisabled();
});

test('422 rejection errors map to the reason field and restore usable focus', async ({ page }) => {
  await accountApi(page, { role: 'moderator', failure: 'reason_too_long' });
  await openCard(page);
  const reason = page.getByLabel('rejection reason', { exact: true });
  await reason.fill('A reason');
  page.once('dialog', (dialog) => dialog.accept());
  await page.getByRole('button', { name: 'reject — final', exact: true }).click();
  await expect(reason).toHaveAttribute('aria-invalid', 'true');
  await expect(reason).toHaveAccessibleDescription(/reason too long/);
  await expect(reason).toBeFocused();
});
