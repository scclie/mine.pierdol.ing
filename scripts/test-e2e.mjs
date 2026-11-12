import { resolve } from 'node:path';
import { localRun, freshPort, zigArgs } from './test-local.mjs';
import { chromium } from '@playwright/test';
import { runPlaywright } from './test-playwright.mjs';

await localRun('e2e', async ({ directory, database, env, start, command, wait, ownBrowser, afterStop }) => {
  await command('node', ['--test', 'tests/build-commit.test.mjs', 'tests/playwright-config.test.mjs', 'tests/docs-api.test.mjs', 'tests/runner-safety.test.mjs', 'tests/runner-database.test.mjs']);
  await command('zig', ['build', 'release-server', ...zigArgs(directory)]);
  const [apiPort, staticPort, oauthPort, mockPort] = await Promise.all(Array.from({ length: 4 }, freshPort));
  if (new Set([apiPort, staticPort, oauthPort, mockPort]).size !== 4) throw new Error('port allocation collision; rerun');
  const origin = `http://127.0.0.1:${staticPort}`;
  const oauthOrigin = `http://127.0.0.1:${oauthPort}`;
  const apiOrigin = `http://127.0.0.1:${apiPort}`;
  const callback = `${origin}/api/v1/auth/discord/callback`;
  const oauth = await start('node', ['tests/support/release-http.mjs'], { MODE: 'oauth', PORT: String(oauthPort), CALLBACK: callback }, 'oauth.log');
  await wait(async () => (await fetch(`${oauthOrigin}/__ready`)).status === 200, oauth);
  const api = await start(`${directory}/zig-out/bin/release-api`, [], {
    DATABASE_URL: database, HTTP_LISTEN_ADDRESS: `127.0.0.1:${apiPort}`, PUBLIC_ORIGIN: origin,
    DISCORD_CLIENT_ID: 'local', DISCORD_CLIENT_SECRET: 'local-only', DISCORD_REDIRECT_URI: callback,
    SESSION_SIGNING_KEY: 'local-verification-key-not-a-real-secret', DEVELOPMENT_MODE: 'true',
    ADMIN_DISCORD_IDS: '3001', MODERATOR_DISCORD_IDS: '2001', TASK12_OAUTH_ORIGIN: oauthOrigin,
  }, 'api.log');
  // a missing health endpoint is a release limitation, not a fabricated 200.
  await wait(async () => (await fetch(`${apiOrigin}/api/v1/account`)).status === 401, api);
  const health = await fetch(`${apiOrigin}/api/v1/healthz`);
  if (health.status !== 404 || (await health.json()).error.code !== 'not_found') throw new Error('update documented health contract');
  console.log('Health limitation confirmed: GET /api/v1/healthz => 404 not_found; readiness uses account => 401.');
  const facade = await start('node', ['tests/support/release-http.mjs'], { MODE: 'static', PORT: String(staticPort), API_ORIGIN: apiOrigin }, 'static.log');
  await wait(async () => (await fetch(`${origin}/__ready`)).ok, facade);
  const fixtureOrigin = `http://127.0.0.1:${mockPort}`;
  const fixtures = await start('node', ['tests/support/static-server.mjs'], { PORT: String(mockPort), TASK10_OAUTH_STUB: '1' }, 'fixtures.log');
  await wait(async () => (await fetch(`${fixtureOrigin}/__ready`)).ok, fixtures);
  const browserExecutable = await ownBrowser(process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH || chromium.executablePath());
  env.TASK12_DATABASE_URL = database;
  env.TASK12_RUN_DIR = directory;
  env.TASK12_ORIGIN = origin;
  env.TASK12_OAUTH_ORIGIN = oauthOrigin;
  await runPlaywright({ directory, env, start, afterStop, args: process.argv.slice(2), config: {
    testDir: resolve('tests/e2e'), workers: 1, timeout: 30000,
    use: { launchOptions: { executablePath: browserExecutable } },
    projects: [
      { name: 'desktop', testIgnore: '**/release-smoke.spec.mjs', use: { baseURL: fixtureOrigin, viewport: { width: 1440, height: 1000 } } },
      { name: 'mobile', testIgnore: '**/release-smoke.spec.mjs', use: { baseURL: fixtureOrigin, viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true } },
      { name: 'chromium', testMatch: '**/release-smoke.spec.mjs', use: { baseURL: origin, viewport: { width: 1440, height: 1000 } } },
      { name: 'mobile-release', testMatch: '**/release-smoke.spec.mjs', use: { baseURL: origin, viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true } },
    ],
  } });
});
