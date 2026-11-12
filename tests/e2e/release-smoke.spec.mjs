import { test, expect } from '@playwright/test';
import { randomBytes } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { mkdir, readFile } from 'node:fs/promises';
import { fillPassword, registerPasswords } from '../support/password.mjs';

test('independent browsers reject missing and foreign OAuth binding without session swapping', async ({ browser }) => {
  const origin = process.env.TASK12_ORIGIN;
  const contexts = await Promise.all(Array.from({ length: 3 }, () => browser.newContext()));
  const [initiator, victim, unbound] = contexts;
  const session = async context => (await context.cookies()).find(cookie => cookie.name === 'mine_session')?.value;
  async function pending(context, identity) {
    await context.request.get(`${process.env.TASK12_OAUTH_ORIGIN}/identity/${identity}`);
    const begin = await context.request.get(`${origin}/api/v1/auth/discord`, { maxRedirects: 0 });
    expect(begin.status()).toBe(302);
    const binding = (await context.cookies()).find(cookie => cookie.name === 'mine_oauth');
    expect(Boolean(binding?.httpOnly && binding.sameSite === 'Lax' && binding.path === '/')).toBe(true);
    registerPasswords([binding.value]);
    const authorize = begin.headers().location;
    registerPasswords([new URL(authorize).searchParams.get('state')]);
    expect(authorize.includes(binding.value), 'binding is never a URL parameter').toBe(false);
    const provider = await context.request.get(authorize, { maxRedirects: 0 });
    expect(provider.status()).toBe(302);
    const callback = provider.headers().location;
    registerPasswords([new URL(callback).searchParams.get('code')]);
    return { callback, binding: binding.value, state: new URL(callback).searchParams.get('state') };
  }
  async function reject(context, callback) {
    const response = await context.request.get(callback, { maxRedirects: 0 });
    expect(response.status()).toBe(400);
    expect((await response.json()).error.code).toBe('oauth_state_invalid');
    expect(response.headersArray().some(header => header.name.toLowerCase() === 'set-cookie' && header.value.startsWith('mine_session='))).toBe(false);
  }
  try {
    const victimLogin = await pending(victim, 'moderator');
    expect((await victim.request.get(victimLogin.callback, { maxRedirects: 0 })).status()).toBe(302);
    const previous = await session(victim);
    registerPasswords([previous]);
    const previousUser = (await (await victim.request.get(`${origin}/api/v1/account`)).json()).user.id;
    const a = await pending(initiator, 'player-desktop');
    const b = await pending(victim, 'moderator');
    expect(a.binding === b.binding).toBe(false);
    await reject(unbound, a.callback);
    expect(Boolean(await session(unbound))).toBe(false);
    await reject(victim, a.callback);
    expect((await session(victim)) === previous, 'victim session is unchanged').toBe(true);
    expect((await (await victim.request.get(`${origin}/api/v1/account`)).json()).user.id).toBe(previousUser);
    const accepted = await initiator.request.get(a.callback, { maxRedirects: 0 });
    expect(accepted.status()).toBe(302);
    expect(accepted.headers().location).toBe('/account');
    const issued = await session(initiator);
    registerPasswords([issued]);
    expect(Boolean(issued)).toBe(true);
    expect((await initiator.cookies()).some(cookie => cookie.name === 'mine_oauth')).toBe(false);
    await reject(initiator, a.callback);
    expect((await session(initiator)) === issued).toBe(true);
    const logs = await readFile(`${process.env.TASK12_RUN_DIR}/api.log`, 'utf8');
    for (const secret of [a.binding, b.binding, a.state, previous, issued, new URL(a.callback).searchParams.get('code')])
      expect(logs.includes(secret), 'API logs exclude OAuth/session secrets').toBe(false);
  } finally {
    const closed = await Promise.allSettled(contexts.map(context => context.close()));
    if (closed.some(result => result.status === 'rejected')) throw new Error('OAuth regression context cleanup failed');
  }
});

test('release lifecycle and secret-free audit', async ({ browser }, info) => {
  expect(process.env.TASK12_DATABASE_URL, 'release runner must supply a disposable database').toBeTruthy();
  const directory = process.env.TASK12_RUN_DIR;
  const passwords = [randomBytes(24).toString('base64url'), randomBytes(24).toString('base64url')];
  registerPasswords(passwords);
  const contexts = [];
  async function login(identity) {
    const context = await browser.newContext({ viewport: info.project.use.viewport });
    contexts.push(context);
    await context.request.get(`${process.env.TASK12_OAUTH_ORIGIN}/identity/${identity}`);
    const page = await context.newPage();
    await page.goto(`${process.env.TASK12_ORIGIN}/login`);
    await page.locator('a[href^="/api/v1/auth/discord"]').click();
    await expect(page.locator('[data-account-state]')).toBeVisible();
    return page;
  }
  async function account(page) {
    const response = await page.request.get(`${process.env.TASK12_ORIGIN}/api/v1/account`);
    expect(response.status()).toBe(200);
    return response.json();
  }
  async function mutate(page, method, path, data, status) {
    const csrf = (await account(page)).csrf_token;
    const response = await page.request.fetch(`${process.env.TASK12_ORIGIN}${path}`, {
      method, data, headers: { 'X-CSRF-Token': csrf },
    });
    expect(response.status()).toBe(status);
    return response;
  }
  async function application(page, password, button) {
    const nickname = page.getByLabel('minecraft nickname', { exact: true });
    const expected = `Release_${info.project.name.includes('mobile') ? 'M' : 'D'}`;
    if (button === 'resubmit application') {
      await expect(nickname).not.toBeEditable();
      await expect(nickname).toHaveValue(expected);
    } else {
      await nickname.fill(expected);
    }
    await page.getByLabel('client type', { exact: true }).selectOption('cracked');
    await page.getByLabel('about me', { exact: true }).fill('Disposable release verification applicant.');
    await page.getByLabel('discovery source', { exact: true }).fill('Local smoke test');
    await fillPassword(page.getByLabel('password', { exact: true }), password);
    await page.getByRole('button', { name: button, exact: true }).click();
    await expect(page.locator('[data-account-state]')).toHaveText('pending');
  }
  try {
    const player = await login(info.project.name.includes('mobile') ? 'player-mobile' : 'player-desktop');
    const playerId = (await account(player)).user.id;
    await player.reload();
    await application(player, passwords[0], 'submit application');
    const moderator = await login('moderator');
    expect((await account(moderator)).user.role).toBe('moderator');
    const admin = await login('administrator');
    expect((await account(admin)).user.role).toBe('administrator');
    const reason = 'Please provide more detail <not markup>.';
    await mutate(moderator, 'POST', `/api/v1/admin/applications/${playerId}/reject`, { kind: 'retryable', reason }, 204);
    const beforeRetry = execFileSync('psql', [process.env.TASK12_DATABASE_URL, '-XAt', '-c',
      `SELECT row_to_json(a) FROM applications a WHERE user_id=${playerId}`], { encoding: 'utf8' });
    const retryToken = (await account(player)).csrf_token;
    const forged = await player.request.patch(`${process.env.TASK12_ORIGIN}/api/v1/account/application`, {
      headers: { 'X-CSRF-Token': retryToken },
      data: { minecraft_nickname: 'Forbidden_Rename', client_type: 'licensed', about_me: 'Attempted overwrite', discovery_source: 'Forged' },
    });
    expect(forged.status()).toBe(409);
    expect((await forged.json()).error.code).toBe('nickname_immutable');
    expect(execFileSync('psql', [process.env.TASK12_DATABASE_URL, '-XAt', '-c',
      `SELECT row_to_json(a) FROM applications a WHERE user_id=${playerId}`], { encoding: 'utf8' })).toBe(beforeRetry);
    await player.reload();
    await expect(player.locator('[data-decision-reason]')).toHaveText(reason);
    await application(player, passwords[0], 'resubmit application');
    await mutate(moderator, 'POST', `/api/v1/admin/applications/${playerId}/approve`, {}, 204);
    await player.reload();
    await expect(player.locator('[data-account-state]')).toHaveText('approved');
    await fillPassword(player.getByLabel('password', { exact: true }), passwords[1]);
    await player.getByRole('button', { name: 'save password', exact: true }).click();
    await expect(player.getByRole('status')).toHaveText('password saved');
    const banReason = 'Release ban reason <literal>.';
    await mutate(admin, 'PATCH', `/api/v1/admin/users/${playerId}`, { status: 'banned', reason: banReason }, 204);
    expect((await player.request.get(`${process.env.TASK12_ORIGIN}/api/v1/account`)).status()).toBe(401);
    const banned = await login(info.project.name.includes('mobile') ? 'player-mobile' : 'player-desktop');
    await expect(banned.locator('[data-account-state]')).toHaveText('banned');
    await expect(banned.locator('[data-decision-reason]')).toHaveText(banReason);
    await expect(banned.locator('main form')).toHaveCount(0);
    await mutate(banned, 'POST', '/api/v1/account/password', { password: passwords[1] }, 403);
    await mkdir(`${directory}/screenshots`, { recursive: true });
    await banned.screenshot({ path: `${directory}/screenshots/banned-${info.project.name}.png`, fullPage: true });
    await mutate(admin, 'PATCH', `/api/v1/admin/users/${playerId}`, { status: 'approved' }, 204);
    await banned.reload();
    await expect(banned.locator('[data-account-state]')).toHaveText('approved');
    await expect(banned.locator('[data-reason-row]')).toBeHidden();
    await banned.screenshot({ path: `${directory}/screenshots/unbanned-${info.project.name}.png`, fullPage: true });
    const audit = JSON.parse(execFileSync('psql', [process.env.TASK12_DATABASE_URL, '-XAt', '-c',
      `SELECT coalesce(json_agg(a ORDER BY id), '[]') FROM audit_log a WHERE subject_user_id=${playerId}`], { encoding: 'utf8' }));
    expect(audit.map(row => row.action)).toEqual([
      'application_created', 'application_rejected_retryable', 'application_resubmitted',
      'application_approved', 'password_changed', 'user_banned', 'user_unbanned',
    ]);
    expect(audit.map(row => row.actor_user_id)).toEqual([playerId, (await account(moderator)).user.id, playerId,
      (await account(moderator)).user.id, playerId, (await account(admin)).user.id, (await account(admin)).user.id]);
    const serialized = JSON.stringify(audit);
    const logs = await readFile(`${directory}/api.log`, 'utf8');
    for (const password of passwords) {
      // Boolean assertions never print raw secrets on failure.
      expect(serialized.includes(password), 'audit must redact passwords').toBe(false);
      expect(logs.includes(password), 'API log must redact passwords').toBe(false);
    }
    for (const row of audit) for (const value of [row.old_value, row.new_value]) {
      expect(Object.keys(value ?? {}).every(key => ['status', 'nickname', 'discord_id', 'client_type', 'created_at', 'updated_at', 'submitted_at', 'decided_at', 'changed_at'].includes(key))).toBe(true);
    }
  } finally {
    const closed = await Promise.allSettled(contexts.map(context => Promise.resolve().then(() => context.close())));
    const failures = closed.filter(result => result.status === 'rejected').map(result => result.reason);
    if (failures.length) throw new AggregateError(failures, 'release browser context cleanup failed');
  }
});
