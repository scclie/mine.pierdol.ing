import { localRun } from '../../scripts/test-local.mjs';
import { mkdir, readFile, symlink, writeFile } from 'node:fs/promises';
import { setTimeout as delay } from 'node:timers/promises';
import vm from 'node:vm';
import assert from 'node:assert/strict';
import { appendFileSync, readFileSync } from 'node:fs';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { runPlaywright } from '../../scripts/test-playwright.mjs';
import { event, processIdentity } from './runner-events.mjs';
import { createRequire, syncBuiltinESMExports } from 'node:module';
import { chromium } from '@playwright/test';

const recorder = new URL('./runner-events.mjs', import.meta.url).href;
const browserExecutable = process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH || chromium.executablePath();

async function smoke(directory) {
  // execute the actual smoke
  let body;
  const shim = new vm.SyntheticModule(['test', 'expect'], function () {
    this.setExport('test', (_name, callback) => { body = callback; });
    this.setExport('expect', (value, message) => ({ toBeTruthy() { assert.ok(value, message); } }));
  });
  const module = new vm.SourceTextModule(await readFile(new URL('../e2e/release-smoke.spec.mjs', import.meta.url), 'utf8'));
  await module.link(async name => {
    if (name === '@playwright/test') return shim;
    const exports = await import(name);
    return new vm.SyntheticModule(Object.keys(exports), function () {
      for (const [key, value] of Object.entries(exports)) this.setExport(key, value);
    });
  });
  await module.evaluate();
  process.env.TASK12_DATABASE_URL = 'unused-test-only';
  process.env.TASK12_RUN_DIR = directory;
  process.env.TASK12_SECRET_FILE = `${directory}/secrets/password-redactions.jsonl`;
  // epresents any browser/worker scratch left behind on abrupt worker exit.
  await mkdir(`${directory}/secrets`, { recursive: true, mode: 0o700 });
  await writeFile(`${directory}/secrets/worker-secret`, 'synthetic-plaintext-password', { mode: 0o600 });
  const browser = { async newContext() {
    return {
      request: { async get() {
        await event('smoke');
        if (process.env.SCENARIO === 'smoke-interrupt') return new Promise(() => {});
        throw new Error('synthetic browser request failure');
      } },
      async close() { await event('context-close'); throw new Error('synthetic context close failure'); },
    };
  } };
  await body({ browser }, { project: { name: 'cleanup-probe', use: { viewport: {} } } });
}

try {
  await localRun('regression', async ({ directory, env, start, ownBrowser, afterStop }) => {
    if (['failed-fill', 'stopped-browser', 'browser-exit', 'browser-orphan', 'browser-race'].includes(process.env.SCENARIO)) {
      // keep chromium socket paths short, even in nested tests
      // alias only this run's secrets; outer cleanup owns the profile
      await symlink(`${directory}/secrets`, `${process.env.CASE_DIR}/tmp`);
      env.TMPDIR = `${process.env.CASE_DIR}/tmp`;
    }
    if (process.env.SCENARIO === 'environment') {
      await writeFile(`${process.env.CASE_DIR}/client-env.json`, JSON.stringify(
        Object.fromEntries(Object.entries(env).filter(([key]) => key.startsWith('PG')))));
    } else if (process.env.SCENARIO === 'failed-fill') {
      const executable = await ownBrowser(browserExecutable);
      const specs = `${process.env.CASE_DIR}/specs`;
      await mkdir(specs, { mode: 0o700 });
      const passwords = fileURLToPath(new URL('./password.mjs', import.meta.url));
      await writeFile(`${specs}/password.spec.mjs`, `
        import { test } from ${JSON.stringify(fileURLToPath(new URL('../../node_modules/@playwright/test/index.mjs', import.meta.url)))};
        import { randomBytes } from 'node:crypto';
        import { writeFileSync } from 'node:fs';
        import { event } from ${JSON.stringify(recorder)};
        import * as boundary from ${JSON.stringify(passwords)};
        for (const state of ['disabled', 'readonly']) test('failed password fill: ' + state, async ({page}) => {
          const password = randomBytes(24).toString('base64url');
          boundary.registerPasswords([password]);
          console.log('synthetic secret-console probe: ' + password);
          console.error('synthetic secret-stderr probe: ' + password);
          writeFileSync(process.env.PGHOST + '/secrets/probe-' + state, password, {mode:0o600});
          event('password-' + state, process.pid, {runDirectory:process.env.PGHOST});
          // Leave time for the external test owner to retain the value IN MEMORY.
          await new Promise(resolve => setTimeout(resolve, 300));
          await page.setContent('<label>password<input type="password" ' + state + '></label>');
          await boundary.fillPassword(page.getByLabel('password'), password, {timeout:350});
        });
      `, { mode: 0o600 });
      const config = { testDir: specs, workers: 1, timeout: 5000,
        use: { trace: 'off', video: 'off', screenshot: 'off', launchOptions: { executablePath: executable } } };
      await runPlaywright({ directory, env, start, afterStop, config });
    } else if (['browser-exit', 'browser-orphan', 'browser-race'].includes(process.env.SCENARIO)) {
      await writeFile(`${directory}/secrets/resistant.mjs`, `
        import { event } from ${JSON.stringify(recorder)};
        process.on('SIGTERM', () => {});
        event('browser-descendant');
        setInterval(() => {}, 1000);
      `, { mode: 0o600 });
      await writeFile(`${directory}/secrets/chromium-with-descendant`, `#!/bin/sh\n${process.execPath} ${directory}/secrets/resistant.mjs </dev/null >/dev/null 2>&1 3<&- 4<&- &\nexec ${browserExecutable} "$@"\n`, { mode: 0o700 });
      const executable = await ownBrowser(`${directory}/secrets/chromium-with-descendant`);
      const owner = await start(process.execPath, ['--input-type=module', '-e', `
        import { chromium } from '@playwright/test';
        import { readFileSync, readdirSync } from 'node:fs';
        import { event } from ${JSON.stringify(recorder)};
        const browser = await chromium.launchServer({executablePath:${JSON.stringify(executable)},headless:true});
        while (!readFileSync(process.env.CASE_DIR + '/events.jsonl', 'utf8').includes('browser-descendant')) await new Promise(resolve => setTimeout(resolve,20));
        if (process.env.SCENARIO !== 'browser-exit') {
          const supervisor = browser.process().pid;
          const child = readdirSync('/proc').filter(name => /^\\d+$/.test(name)).find(name => {
            try { return Number(readFileSync('/proc/' + name + '/stat', 'utf8').split(') ')[1].split(' ')[1]) === supervisor; } catch { return false; }
          });
          event('browser-supervisor', supervisor);
          event('browser-child', Number(child));
          process.kill(Number(child), 'SIGSTOP');
          process.kill(process.pid, 'SIGKILL');
        } else await browser.close();
      `], {}, 'browser-owner.log');
      const result = await owner.done;
      if (process.env.SCENARIO !== 'browser-exit') {
        if (result.signal !== 'SIGKILL') throw new Error('browser owner must exit abruptly');
        const rows = (await readFile(`${process.env.CASE_DIR}/events.jsonl`, 'utf8')).trim().split('\n').map(JSON.parse);
        const child = rows.find(row => row.stage === 'browser-child');
        const supervisor = rows.find(row => row.stage === 'browser-supervisor');
        if (process.env.SCENARIO === 'browser-race') {
          const fs = createRequire(import.meta.url)('node:fs');
          const original = fs.readFileSync;
          const registry = JSON.parse(env.TASK12_GROUP_REGISTRIES).at(-1);
          let raced = false;
          fs.readFileSync = (file, ...args) => {
            const value = original(file, ...args);
            if (file === registry && !raced) {
              raced = true;
              if (processIdentity(child.pid)?.born === child.born) process.kill(child.pid, 'SIGKILL');
              // pause the reader after its snapshot so the supervisor can finish
              // publishing membership and exit before cleanup
              for (let i = 0; i < 400; i++) {
                try { if (original(`/proc/${supervisor.pid}/stat`, 'utf8').split(') ')[1][0] === 'Z') break; }
                catch (error) { if (error.code === 'ENOENT') break; throw error; }
                Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 5);
              }
            }
            return value;
          };
          syncBuiltinESMExports();
        } else {
          if (processIdentity(child.pid)?.born === child.born) process.kill(child.pid, 'SIGKILL');
          for (let i = 0; i < 100; i++) {
            const current = processIdentity(supervisor.pid);
            if (!current || current.state === 'Z') break;
            await delay(20);
          }
        }
      } else if (result.code !== 0) throw new Error('real browser owner failed');
    } else if (process.env.SCENARIO === 'stopped-browser') {
      const executable = ownBrowser ? await ownBrowser(browserExecutable) : browserExecutable;
      await start(process.execPath, ['--input-type=module', '-e', `
        import { chromium } from '@playwright/test';
        import { event } from ${JSON.stringify(recorder)};
        const browser = await chromium.launchServer({executablePath:${JSON.stringify(executable)},headless:true});
        const pid = browser.process().pid;
        // Playwright directly creates this detached session; it does not import
        // localRun or cooperate with its registry. Freeze the REAL browser so
        // pipe disconnection/graceful close cannot rescue outer ownership.
        process.kill(-pid, 'SIGSTOP');
        event('browser-stopped', pid, {runDirectory:process.env.PGHOST});
        setInterval(() => {}, 1000);
      `], {}, 'browser-owner.log');
      await new Promise(() => {});
    } else if (process.env.SCENARIO === 'term-descendant') {
      const leader = await start(process.execPath, ['--input-type=module', '-e', `
        import { spawn } from 'node:child_process';
        process.on('SIGTERM', () => process.exit(0));
        spawn(process.execPath, ['--input-type=module', '-e', ${JSON.stringify(String.raw`
          import { event } from ${JSON.stringify(recorder)};
          process.on('SIGTERM', () => {});
          event('term-descendant');
          setInterval(() => {}, 1000);
        `)}], {stdio:'ignore'});
      `]);
      for (let i = 0; i < 100; i++) {
        if ((await readFile(`${process.env.CASE_DIR}/events.jsonl`, 'utf8')).includes('term-descendant')) break;
        await delay(20);
      }
      const kill = process.kill.bind(process);
      process.kill = (pid, signal) => {
        const result = kill(pid, signal);
        if (pid === -leader.pid && signal === 'SIGTERM') {
          // hold the node exit callback until the leader has exited,
          // while keeping the resistant child process alive
          for (let i = 0; i < 200; i++) {
            try { if (readFileSync(`/proc/${leader.pid}/stat`, 'utf8').split(') ')[1][0] === 'Z') break; }
            catch (error) { if (error.code === 'ENOENT') break; throw error; }
            Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 5);
          }
        }
        return result;
      };
    } else if (process.env.SCENARIO === 'reused-group') {
      // simulate an unrelated live group reusing a stale registry id.
      const sentinel = spawn(process.execPath, ['-e', 'setInterval(() => {}, 1000)'], { detached: true, stdio: 'ignore' });
      sentinel.unref();
      await event('reused-sentinel', sentinel.pid);
      const registry = JSON.parse(env.TASK12_GROUP_REGISTRIES).at(-1);
      appendFileSync(registry, `${JSON.stringify({ pid: sentinel.pid, born: '0', members: [{ pid: sentinel.pid, born: '0' }] })}\n`);
    } else if (process.env.SCENARIO === 'stale-group') {
      const rows = (await readFile(`${process.env.CASE_DIR}/events.jsonl`, 'utf8')).trim().split('\n').map(JSON.parse);
      const expired = rows.find(row => row.stage === 'initdb').pid;
      const kill = process.kill.bind(process);
      let vanished = false;
      // simulate kernel id reuse without signaling unrelated processes
      // after ESRCH, the id is no longer owned by us
      process.kill = (pid, signal) => {
        if (pid === -expired) {
          if (signal === 0) {
            vanished = true;
            throw Object.assign(new Error('simulated vanished group'), { code: 'ESRCH' });
          }
          if (vanished) event('stale-group-signaled');
        }
        return kill(pid, signal);
      };
    } else if (process.env.SCENARIO === 'nested-owner') {
      const nested = await start(process.execPath, [new URL(import.meta.url).pathname], { SCENARIO: 'nested-inner' }, 'nested.log');
      const result = await nested.done;
      if (result.code !== 0) throw new Error('nested owner failed');
    } else if (process.env.SCENARIO === 'nested-inner') {
      await start(process.execPath, ['--input-type=module', '-e', String.raw`
        import { event } from ${JSON.stringify(recorder)};
        process.on('SIGTERM', () => {});
        event('nested-descendant');
        setInterval(() => {}, 1000);
      `]);
      for (let i = 0; i < 100; i++) {
        if ((await readFile(`${process.env.CASE_DIR}/events.jsonl`, 'utf8')).includes('nested-descendant')) process.exit(0);
        await delay(20);
      }
      throw new Error('nested descendant did not start');
    } else if (process.env.SCENARIO === 'exited-leader') {
      const leader = await start(process.execPath, ['--input-type=module', '-e', `
        import { spawn } from 'node:child_process';
        const child = spawn(process.execPath, ['--input-type=module', '-e', ${JSON.stringify(String.raw`
          import { event } from ${JSON.stringify(recorder)};
          process.on('SIGTERM', () => {});
          event('descendant');
          setInterval(() => {}, 1000);
        `)}], {stdio:'ignore'});
        child.unref();
      `]);
      await leader.done;
      for (let i = 0; i < 100; i++) {
        if ((await readFile(`${process.env.CASE_DIR}/events.jsonl`, 'utf8')).includes('descendant')) return;
        await delay(20);
      }
      throw new Error('descendant did not start');
    } else if (process.env.SCENARIO === 'late-start') {
      await event('running');
      await delay(300);
      try {
        const child = await start(process.execPath, ['-e', 'setInterval(() => {}, 1000)']);
        await event('late-start-accepted', child.pid);
      } catch { await event('late-start-refused'); }
    } else if (process.env.SCENARIO === 'teardown') {
      await start(process.execPath, ['--input-type=module', '-e', String.raw`
        import { event } from ${JSON.stringify(recorder)};
        process.on('SIGTERM', () => {
          event('terminating');
        });
        event('stubborn');
        setInterval(() => {}, 1000);
      `]);
      for (let i = 0; i < 100; i++) {
        if ((await readFile(`${process.env.CASE_DIR}/events.jsonl`, 'utf8')).includes('stubborn')) return;
        await delay(20);
      }
    } else if (process.env.SCENARIO.startsWith('smoke-')) {
      await smoke(directory);
    } else {
      await event('unexpected-run');
    }
  });
} catch (error) {
  console.error(error.message);
  process.exitCode = 1;
}
