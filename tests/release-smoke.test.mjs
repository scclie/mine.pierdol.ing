import test from 'node:test';
import assert from 'node:assert/strict';
import { localRun, freshPort, zigArgs } from '../scripts/test-local.mjs';

test('release HTTP health, authentication boundary, and static root', async () => {
  await localRun('release-smoke', async ({ directory, database, command, start, wait }) => {
    await command('zig', ['build', 'release-server', ...zigArgs(directory)]);
    const [apiPort, staticPort, oauthPort] = await Promise.all([freshPort(), freshPort(), freshPort()]);
    assert.equal(new Set([apiPort, staticPort, oauthPort]).size, 3, 'fresh ports must be distinct');
    const origin = `http://127.0.0.1:${staticPort}`;
    const apiOrigin = `http://127.0.0.1:${apiPort}`;
    const oauthOrigin = `http://127.0.0.1:${oauthPort}`;
    const callback = `${origin}/api/v1/auth/discord/callback`;
    const oauth = await start('node', ['tests/support/release-http.mjs'], {
      MODE: 'oauth', PORT: String(oauthPort), CALLBACK: callback,
    }, 'oauth.log');
    await wait(async () => (await fetch(`${oauthOrigin}/__ready`)).status === 200, oauth);
    const api = await start(`${directory}/zig-out/bin/release-api`, [], {
      DATABASE_URL: database, HTTP_LISTEN_ADDRESS: `127.0.0.1:${apiPort}`, PUBLIC_ORIGIN: origin,
      DISCORD_CLIENT_ID: 'local', DISCORD_CLIENT_SECRET: 'local-only', DISCORD_REDIRECT_URI: callback,
      SESSION_SIGNING_KEY: 'local-verification-key-not-a-real-secret', DEVELOPMENT_MODE: 'true',
      ADMIN_DISCORD_IDS: '3001', MODERATOR_DISCORD_IDS: '2001', TASK12_OAUTH_ORIGIN: oauthOrigin,
    }, 'api.log');
    await wait(async () => {
      const response = await fetch(`${apiOrigin}/api/v1/healthz`, { redirect: 'error' });
      await response.body?.cancel();
      return true;
    }, api);
    const facade = await start('node', ['tests/support/release-http.mjs'], {
      MODE: 'static', PORT: String(staticPort), API_ORIGIN: apiOrigin,
    }, 'static.log');
    await wait(async () => (await fetch(`${origin}/__ready`)).status === 200, facade);

    const health = await fetch(`${origin}/api/v1/healthz`, { redirect: 'error' });
    assert.equal(health.status, 200, 'release health status');
    assert.deepEqual(await health.json(), { status: 'ok' });
    const account = await fetch(`${origin}/api/v1/account`, { redirect: 'error' });
    assert.equal(account.status, 401, 'unauthenticated account status');
    await account.body?.cancel();
    const root = await fetch(origin, { redirect: 'error' });
    assert.equal(root.status, 200, 'static root status');
    await root.body?.cancel();
  });
});
