import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { createServer } from 'node:net';
import { createServer as createHttpServer } from 'node:http';
import { setTimeout } from 'node:timers/promises';
import config from '../playwright.config.mjs';

async function withServer(env, run) {
  const probe = createServer();
  await new Promise((resolve, reject) => {
    probe.once('error', error => reject(error.code === 'EADDRINUSE' ? new Error('Port 3105 is already in use') : error));
    probe.listen(3105, '127.0.0.1', resolve);
  });
  await new Promise(resolve => probe.close(resolve));
  const server = spawn(config.webServer.command, {
    shell: true, detached: true, stdio: 'ignore',
    env: { ...process.env, TASK10_OAUTH_STUB: '', ...env, PORT: '3105' },
  });
  const exited = new Promise(resolve => server.once('exit', resolve));
  try {
    let ready = false;
    for (let attempt = 0; attempt < 100; attempt++) {
      assert.equal(server.exitCode, null, 'test server must remain running');
      try { ready = (await fetch('http://127.0.0.1:3105/__ready')).ok; } catch {}
      if (ready) break;
      await setTimeout(50);
    }
    assert.ok(ready, 'isolated test server starts');
    await run();
  } finally {
    try { process.kill(-server.pid, 'SIGTERM'); } catch (error) {
      if (error.code !== 'ESRCH') throw error;
    }
    await exited;
  }
}

test('repository default E2E server enables local OAuth navigation', async () => {
  await withServer(config.webServer.env, async () => {
    const login = await fetch('http://127.0.0.1:3105/api/v1/auth/discord', { redirect: 'manual' });
    assert.equal(login.status, 302);
    const callback = await fetch(new URL(login.headers.get('location'), login.url), { redirect: 'manual' });
    assert.equal(callback.status, 302);
    assert.equal(callback.headers.get('location'), '/account');
    assert.match(callback.headers.get('set-cookie'), /^mine_session=[a-f0-9]{64}; Path=\/; HttpOnly; SameSite=Lax$/);
  });
});

test('static test server without explicit opt-in has no OAuth redirects', async () => {
  await withServer({}, async () => {
    for (const path of ['/api/v1/auth/discord', '/api/v1/auth/discord/callback']) {
      const response = await fetch(`http://127.0.0.1:3105${path}`, { redirect: 'manual' });
      assert.equal(response.status, 404);
      assert.equal(response.headers.get('set-cookie'), null);
    }
  });
});

test('configuration regression refuses an occupied isolated port', async () => {
  const occupied = createHttpServer((request, response) => response.end('ready'));
  await new Promise(resolve => occupied.listen(3105, '127.0.0.1', resolve));
  try {
    await assert.rejects(Promise.race([
      withServer({}, async () => assert.fail('must not use an unrelated server')),
      setTimeout(1000).then(() => { throw new Error('fixture cleanup timed out'); }),
    ]), /Port 3105 is already in use/);
  } finally {
    occupied.closeAllConnections();
    await new Promise(resolve => occupied.close(resolve));
  }
});
