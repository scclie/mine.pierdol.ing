import { test, expect } from '@playwright/test';
import { mkdir } from 'node:fs/promises';
import { accountApi, signIn, fillApplication } from '../support/account-api.mjs';

test('new player signs in; cracked password clears on licensed submission', async ({ page }, info) => {
  const api = await accountApi(page);
  await signIn(page);
  await expect(page.getByRole('heading', { name: 'account', exact: true })).toBeVisible();
  await expect(page.locator('[data-nickname-row]')).toBeHidden();
  await expect(page.locator('[data-reason-row]')).toBeHidden();
  await fillApplication(page);
  await page.getByLabel('client type', { exact: true }).selectOption('cracked');
  const password = page.getByLabel('password', { exact: true });
  await expect(password).toBeVisible();
  await expect(password).toHaveAttribute('minlength', '12');
  await expect(password).toHaveAttribute('autocomplete', 'new-password');
  await expect(password).toHaveAccessibleDescription(/at least 12/);
  await password.fill('blue-harbor-falcon-2026');
  await mkdir('/tmp/opencode/task10/screenshots', { recursive: true });
  await page.screenshot({ path: `/tmp/opencode/task10/screenshots/account-${info.project.name}.png`, fullPage: true });
  await page.getByLabel('client type', { exact: true }).selectOption('licensed');
  await expect(password).toBeHidden();
  await expect(password).toHaveValue('');
  await page.getByRole('button', { name: 'submit application', exact: true }).click();
  await expect(page.locator('[data-account-state]')).toHaveText('pending');
  expect(api.mutations[0].body).toEqual({ minecraft_nickname: 'Example_Name', client_type: 'licensed', about_me: 'I build railways.', discovery_source: 'Friend' });
  expect(api.mutations[0].headers['x-csrf-token']).toHaveLength(64);
  expect(api.mutations[0].headers['content-type']).toContain('application/json');
  await expect(page.getByRole('button', { name: 'submit application', exact: true })).toHaveCount(0);
});

test('cracked submission uses JSON and 422 maps inline without retaining password or HTML', async ({ page }) => {
  const api = await accountApi(page, { failure: 'password_denied' });
  await signIn(page);
  await fillApplication(page);
  await page.getByLabel('client type', { exact: true }).selectOption('cracked');
  const password = page.getByLabel('password', { exact: true });
  await password.fill('blue-harbor-falcon-2026');
  await page.getByRole('button', { name: 'submit application', exact: true }).click();
  await expect(password).toHaveAttribute('aria-invalid', 'true');
  await expect(password).toHaveAccessibleDescription(/password denied/);
  await expect(password).toHaveValue('');
  await expect(page.getByLabel('about me', { exact: true })).toHaveValue('I build railways.');
  expect(api.mutations[0].body.password).toBe('blue-harbor-falcon-2026');
  await expect(page.locator('main img')).toHaveCount(0);
});

test('retryable rejection shows literal reason and resubmits with PATCH', async ({ page }) => {
  const api = await accountApi(page, { status: 'rejected_retryable' });
  await signIn(page);
  await expect(page.locator('[data-account-state]')).toHaveText('rejected_retryable');
  await expect(page.locator('[data-decision-reason]')).toHaveText('Please explain <b>more</b>.');
  await expect(page.locator('[data-decision-reason] b')).toHaveCount(0);
  await expect(page.getByLabel('minecraft nickname', { exact: true })).toHaveValue('Subject_Name');
  await fillApplication(page);
  await page.getByRole('button', { name: 'resubmit application', exact: true }).click();
  await expect(page.locator('[data-account-state]')).toHaveText('pending');
  expect(api.mutations[0].method).toBe('PATCH');
});

for (const status of ['rejected_final', 'banned', 'pending', 'approved']) {
  test(`${status} remains read-only for application changes`, async ({ page }) => {
    await accountApi(page, { status });
    await signIn(page);
    await expect(page.locator('[data-account-state]')).toHaveText(status);
    if (['rejected_final', 'banned'].includes(status)) await expect(page.locator('[data-decision-reason]')).toHaveText('Please explain <b>more</b>.');
    await expect(page.locator('main form')).toHaveCount(0);
    await expect(page.getByRole('button')).toHaveText(['sign out']);
  });
}

test('actions, not a guessed status, determine application controls', async ({ page }) => {
  await accountApi(page, { actions: { can_submit: false } });
  await signIn(page);
  await expect(page.locator('[data-account-state]')).toHaveText('no application');
  await expect(page.locator('main form')).toHaveCount(0);
});

test('approved cracked setup refreshes CSRF for another password change and logout', async ({ page }) => {
  const api = await accountApi(page, { status: 'approved', client: 'cracked', setup: true });
  await signIn(page);
  await expect(page.getByText('password setup required', { exact: true })).toBeVisible();
  for (const value of ['blue-harbor-falcon-2026', 'blue-harbor-falcon-2027']) {
    await page.getByLabel('password', { exact: true }).fill(value);
    await page.getByRole('button', { name: 'save password', exact: true }).click();
    await expect(page.getByRole('status')).toHaveText('password saved');
    await expect(page.getByLabel('password', { exact: true })).toHaveValue('');
  }
  expect(api.mutations[0].headers['x-csrf-token']).not.toBe(api.mutations[1].headers['x-csrf-token']);
  await page.getByRole('button', { name: 'sign out', exact: true }).click();
  await expect(page).toHaveURL(/\/login\/?$/);
  expect(api.mutations.at(-1).path).toBe('/api/v1/auth/logout');
});

test('authentication and mutation errors are visible, not false success', async ({ page }) => {
  await accountApi(page, { unauthenticated: true });
  await page.goto('/account');
  await expect(page.getByRole('alert')).toContainText('sign in');
  await expect(page.locator('main form')).toHaveCount(0);
});

test('server denial of an account mutation is visible and clears the password', async ({ page }) => {
  await accountApi(page, { failure: 'account_read_only', failureStatus: 403 });
  await signIn(page);
  await fillApplication(page);
  await page.getByLabel('client type', { exact: true }).selectOption('cracked');
  await page.getByLabel('password', { exact: true }).fill('blue-harbor-falcon-2026');
  await page.getByRole('button', { name: 'submit application', exact: true }).click();
  await expect(page.getByRole('alert')).toHaveText('account read only');
  await expect(page.getByLabel('password', { exact: true })).toHaveValue('');
  await expect(page.locator('[data-account-state]')).toHaveText('no application');
});

test('mobile form fits 320px and has keyboard-visible focus', async ({ page }) => {
  await accountApi(page);
  await signIn(page);
  await page.setViewportSize({ width: 320, height: 844 });
  await page.getByLabel('minecraft nickname', { exact: true }).focus();
  await page.keyboard.press('Tab');
  await expect(page.getByLabel('client type', { exact: true })).toBeFocused();
  await expect(page.getByLabel('client type', { exact: true })).toHaveCSS('outline-style', 'solid');
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
});

test.describe('without JavaScript', () => {
  test.use({ javaScriptEnabled: false });
  test('account has an honest fallback and login link, not a broken JSON form', async ({ page }) => {
    await page.goto('/account');
    await expect(page.getByRole('heading', { name: 'account', exact: true })).toBeVisible();
    await expect(page.locator('noscript p')).toContainText('javascript is required');
    await expect(page.locator('noscript p')).toBeVisible();
    await expect(page.locator('main form')).toHaveCount(0);
    await expect(page.getByRole('main').getByRole('link', { name: 'login', exact: true })).toHaveAttribute('href', '/login');
  });
});
