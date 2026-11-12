import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { access, mkdir, mkdtemp, readFile, readdir, rm, writeFile } from 'node:fs/promises';
import { constants } from 'node:fs';
import { chromium } from '@playwright/test';
import { setTimeout as delay } from 'node:timers/promises';
import { fileURLToPath } from 'node:url';
import { processIdentity, stopEvent } from './support/runner-events.mjs';

const root = '/tmp/opencode/task12-fix-2';
async function alive(pid) {
  try { return (await readFile(`/proc/${pid}/stat`, 'utf8')).split(') ')[1][0] !== 'Z'; }
  catch (error) { if (error.code === 'ENOENT') return false; throw error; }
}
async function events(directory) {
  try { return (await readFile(`${directory}/events.jsonl`, 'utf8')).trim().split('\n').filter(Boolean).map(line => JSON.parse(line)); }
  catch (error) { if (error.code === 'ENOENT') return []; throw error; }
}
async function until(check) {
  for (let i = 0; i < 250; i++) { if (await check()) return; await delay(20); }
  throw new Error('subprocess condition timed out');
}
async function scenario(name, run, extraEnv = {}) {
  await mkdir(root, { recursive: true, mode: 0o700 });
  const directory = await mkdtemp(`${root}/case-${name}-`);
  const bin = `${directory}/bin`;
  await mkdir(bin, { mode: 0o700 });
  for (const command of ['initdb', 'postgres', 'pg_isready']) {
    await writeFile(`${bin}/${command}`, `#!${process.execPath}\nimport ${JSON.stringify(new URL('./support/runner-safety-fixture.mjs', import.meta.url).href)};\n`, { mode: 0o700 });
  }
  let output = '';
  const sensitive = [];
  const redacted = text => sensitive.reduce((value, secret) => value.replaceAll(secret, '[REDACTED]'), text);
  const runner = spawn(process.execPath, ['--experimental-vm-modules', fileURLToPath(new URL('./support/runner-safety-child.mjs', import.meta.url))], {
    stdio: ['ignore', 'pipe', 'pipe'],
    env: { ...process.env, PATH: `${bin}:${process.env.PATH}`, CASE_DIR: directory, SCENARIO: name,
      PGHOSTADDR: '127.0.0.2', PGPASSFILE: `${directory}/must-not-read`, PGSERVICE: 'hostile-service',
      PGSERVICEFILE: `${directory}/must-not-read-service`, PGDATABASE: 'hostile-db', PGUSER: 'hostile-user',
      PGOPTIONS: '-c search_path=hostile', PGSSLMODE: 'require', PGFUTURESETTING: 'must-not-inherit', ...extraEnv },
  });
  runner.stdout.on('data', data => { output += data; });
  runner.stderr.on('data', data => { output += data; });
  const done = new Promise((resolve, reject) => { runner.once('error', reject); runner.once('exit', (code, signal) => resolve({ code, signal })); });
  const runnerIdentity = processIdentity(runner.pid);
  const stage = name => until(async () => (await events(directory)).some(row => row.stage === name));
  try {
    await run({ runner, stage, directory, registerSecret: value => sensitive.push(value), done: async () => {
      const result = await Promise.race([done, delay(12000, undefined, { ref: false }).then(() => { throw new Error('runner exit timed out'); })]);
      const runDirectory = output.match(/Local verification artifacts: (\S+)/)?.[1];
      assert.ok(runDirectory, output);
      return { ...result, runDirectory, output };
    } });
  } finally {
    // prevent test leaks; stop only recorded test-owned processes.
    stopEvent(runnerIdentity);
    for (const record of await events(directory)) if (record.pid !== runner.pid) stopEvent(record);
    await done;
    await rm(`${directory}/tmp`, { force: true });
    await writeFile(`${directory}/subprocess.log`, redacted(output), { mode: 0o600 });
    const runDirectory = output.match(/Local verification artifacts: (\S+)/)?.[1];
    if (runDirectory?.startsWith(`${root}/regression-`)) {
      for (const name of await readdir(runDirectory)) {
        if (name === 'pg' || name === 'secrets' || name.startsWith('passwords-')) await rm(`${runDirectory}/${name}`, { recursive: true, force: true });
      }
    }
    // clean up plaintext leaks after assertions, even when RED fails
    // never hide production retention failures
    for (const base of [directory, runDirectory].filter(Boolean)) for (const file of await retainedFiles(base)) {
      const bytes = await readFile(file);
      if (sensitive.some(secret => bytes.includes(Buffer.from(secret)))) await writeFile(file, redacted(bytes.toString()), { mode: 0o600 });
    }
  }
}

test('all disposable client environments discard inherited libpq settings', async () => {
  await scenario('environment', async ({ directory, done }) => {
    const result = await done();
    assert.equal(result.code, 0, result.output);
    const env = JSON.parse(await readFile(`${directory}/client-env.json`, 'utf8'));
    const samples = [env, ...(await events(directory)).filter(row => row.pg).map(row => row.pg)];
    for (const sample of samples) {
      assert.equal(sample.PGHOSTADDR, undefined, 'inherited hostaddr must not escape the Unix socket');
      assert.equal(sample.PGPASSFILE, `${result.runDirectory}/secrets/pgpass`, 'never read an owner password file');
      assert.equal(sample.PGSERVICE, undefined);
      assert.equal(sample.PGFUTURESETTING, undefined, 'unknown PG settings must also be discarded');
      assert.equal(sample.PGSSLMODE, undefined);
      assert.equal(sample.PGHOST, result.runDirectory);
    }
  });
});

for (const name of ['initialization', 'readiness']) for (const signal of ['SIGINT', 'SIGTERM']) {
  test(`${signal} during ${name} completes outer cleanup`, async () => {
    await scenario(name, async ({ runner, stage, done, directory }) => {
      await stage('blocked');
      runner.kill(signal);
      const result = await done();
      assert.equal(result.code, 1, result.output);
      assert.doesNotMatch(result.output, /UnhandledPromiseRejection|node:internal\/process\/promises/);
      const cleanup = JSON.parse(await readFile(`${result.runDirectory}/cleanup.json`, 'utf8'));
      assert.equal(cleanup.databaseRemoved, true);
      for (const row of await events(directory)) assert.equal(await alive(row.pid), false, `owned PID ${row.pid} survived`);
      assert.ok(!(await events(directory)).some(row => row.stage === 'unexpected-run'));
    });
  });
}

test('cleanup kills an owned descendant after its group leader exits, not an unrelated process', async () => {
  const unrelated = spawn(process.execPath, ['-e', 'setInterval(() => {}, 1000)'], { stdio: 'ignore' });
  try {
    await scenario('exited-leader', async ({ done, directory }) => {
      const result = await done();
      assert.equal(result.code, 0, result.output);
      const descendant = (await events(directory)).find(row => row.stage === 'descendant');
      assert.ok(descendant);
      assert.equal(await alive(descendant.pid), false, 'leader-exit must not exempt its process group');
      assert.equal(await alive(unrelated.pid), true, 'cleanup must not kill unrelated processes');
    });
  } finally { unrelated.kill('SIGKILL'); }
});

test('cancellation forbids a delayed callback from starting another process', async () => {
  await scenario('late-start', async ({ runner, stage, directory, done }) => {
    await stage('running');
    runner.kill('SIGTERM');
    await until(async () => (await events(directory)).some(row => row.stage.startsWith('late-start-')));
    assert.ok(!(await events(directory)).some(row => row.stage === 'late-start-accepted'));
    assert.ok((await events(directory)).some(row => row.stage === 'late-start-refused'));
    await done();
  });
});

test('outer cleanup owns nested detached groups even when their runner exits abruptly', async () => {
  await scenario('nested-owner', async ({ done, directory }) => {
    const result = await done();
    assert.equal(result.code, 0, result.output);
    const descendant = (await events(directory)).find(row => row.stage === 'nested-descendant');
    assert.ok(descendant);
    assert.equal(await alive(descendant.pid), false, 'nested detached group escaped outer ownership');
    for (const row of await events(directory)) assert.equal(await alive(row.pid), false, `nested PID ${row.pid} survived`);
  });
});

test('cancellation kills a real non-cooperating detached Chromium group before deleting scratch', async () => {
  const unrelated = spawn(process.execPath, ['-e', 'setInterval(() => {}, 1000)'], { detached: true, stdio: 'ignore' });
  try {
    await scenario('stopped-browser', async ({ runner, stage, directory, done }) => {
      await stage('browser-stopped');
      const browser = (await events(directory)).find(row => row.stage === 'browser-stopped');
      const started = Date.now();
      runner.kill('SIGTERM');
      const completion = done();
      let removedWithBrowserAlive = false;
      await until(async () => {
        try { await readdir(`${browser.runDirectory}/secrets`); return false; }
        catch (error) {
          if (error.code !== 'ENOENT') throw error;
          removedWithBrowserAlive = await alive(browser.pid);
          return true;
        }
      });
      const result = await completion;
      assert.equal(result.code, 1, result.output);
      assert.ok(Date.now() - started >= 2900, 'exercise the outer three-second grace, not graceful browser cleanup');
      assert.equal(await alive(browser.pid), false, 'detached Chromium survived owner SIGKILL');
      assert.equal(removedWithBrowserAlive, false, 'scratch disappeared before browser termination');
      assert.equal(await alive(unrelated.pid), true, 'unrelated detached sentinel must survive');
      const cleanup = JSON.parse(await readFile(`${result.runDirectory}/cleanup.json`, 'utf8'));
      assert.ok(cleanup.groups.includes(browser.pid), 'actual browser group must be owned');
      assert.equal(cleanup.groupsGone, true, 'verify disappearance before deleting scratch');
      assert.equal(cleanup.secretsRemoved, true);
      assert.deepEqual(cleanup.cleanupErrors, []);
    });
  } finally { unrelated.kill('SIGKILL'); }
});

const bundleAvailable = await access(chromium.executablePath(), constants.X_OK).then(() => true, error => {
  if (['ENOENT', 'EACCES', 'ENOTDIR'].includes(error.code)) return false;
  throw error;
});
test('unset Chromium override launches the bundled fallback through the resistant-browser supervisor', {
  skip: Boolean(process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH) && !bundleAvailable
    && 'override-only installation: bundled Chromium is not provisioned',
}, async () => {
  await scenario('browser-exit', async ({ done, directory }) => {
    const result = await done();
    assert.equal(result.code, 0, result.output);
    const descendant = (await events(directory)).find(row => row.stage === 'browser-descendant');
    assert.ok(descendant);
    assert.equal(await alive(descendant.pid), false);
  }, { PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH: undefined });
});

for (const name of ['browser-exit', 'browser-orphan', 'browser-race']) test(`${name}: a real browser leader exiting before outer cleanup does not strand a resistant group member`, async () => {
  await scenario(name, async ({ done, directory }) => {
    const result = await done();
    assert.equal(result.code, 0, result.output);
    const descendant = (await events(directory)).find(row => row.stage === 'browser-descendant');
    assert.ok(descendant);
    assert.equal(await alive(descendant.pid), false, 'pre-exec-only browser identities lost the surviving descendant');
  });
});

test('regression teardown does not signal a live unrelated PID named by a stale event', async () => {
  const sentinel = spawn(process.execPath, ['-e', 'setInterval(() => {}, 1000)'], { stdio: 'ignore' });
  try {
    await scenario('environment', async ({ directory, done }) => {
      await done();
      await writeFile(`${directory}/events.jsonl`, `${JSON.stringify({ stage: 'stale-cleanup-event', pid: sentinel.pid, born: '0' })}\n`, { flag: 'a', mode: 0o600 });
    });
    assert.equal(await alive(sentinel.pid), true, 'stale event is not continuing process ownership');
  } finally { sentinel.kill('SIGKILL'); }
});

async function retainedFiles(directory) {
  const files = [];
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    const path = `${directory}/${entry.name}`;
    if (entry.isDirectory()) files.push(...await retainedFiles(path));
    else if (entry.isFile()) files.push(path);
    else assert.fail('unexpected non-regular retained artifact');
  }
  return files;
}

test('real disabled/read-only failed fills leave every retained artifact and reporter serialization secret-free', async () => {
  await scenario('failed-fill', async ({ stage, directory, done, registerSecret }) => {
    const passwords = [];
    for (const state of ['disabled', 'readonly']) {
      await stage(`password-${state}`);
      const { runDirectory } = (await events(directory)).find(row => row.stage === `password-${state}`);
      passwords.push(await readFile(`${runDirectory}/secrets/probe-${state}`, 'utf8'));
      registerSecret(passwords.at(-1));
    }
    const result = await done();
    assert.equal(result.code, 1, 'the real Playwright fills must fail');
    await rm(`${directory}/tmp`, { force: true });
    assert.match(result.output, /not enabled|not editable|read.?only/i, 'retain actionable failure details');
    const files = [...await retainedFiles(result.runDirectory), ...await retainedFiles(directory)];
    let leaked = result.output.includes(passwords[0]) || result.output.includes(passwords[1]);
    for (const file of files) {
      const bytes = await readFile(file);
      if (passwords.some(password => bytes.includes(Buffer.from(password)))) leaked = true;
    }
    assert.equal(leaked, false, 'generated password reached retained diagnostics or console/reporter serialization');
    assert.ok(files.some(file => file.endsWith('error-context.md')), 'retain redacted Playwright error context');
    assert.ok(files.some(file => file.endsWith('report.json')), 'retain redacted reporter results/steps');
    const report = JSON.parse(await readFile(`${result.runDirectory}/results/report.json`, 'utf8'));
    assert.deepEqual(report.tests.map(test => test.status), ['failed', 'failed']);
    for (const test of report.tests) {
      assert.match(test.errors.map(error => error.message).join('\n'), /element is not (enabled|editable)/);
      assert.match(JSON.stringify(test.steps), /\[REDACTED\]/, 'failed internal Playwright step must be redacted too');
    }
    assert.match(result.output, /synthetic secret-console probe: \[REDACTED\]/);
    assert.match(result.output, /synthetic secret-stderr probe: \[REDACTED\]/);
    assert.equal((await readdir(result.runDirectory)).includes('secrets'), false);
  });
});

test('vanished process-group IDs are retired before a numeric ID can be reused', async () => {
  await scenario('stale-group', async ({ done, directory }) => {
    const result = await done();
    assert.equal(result.code, 0, result.output);
    assert.ok(!(await events(directory)).some(row => row.stage === 'stale-group-signaled'), 'never signal an ID after observing its original group vanish');
  });
});

test('a stale registry identity never authorizes signaling a live reused group ID', async () => {
  await scenario('reused-group', async ({ done, directory }) => {
    const result = await done();
    assert.equal(result.code, 0, result.output);
    const sentinel = (await events(directory)).find(row => row.stage === 'reused-sentinel');
    assert.ok(sentinel);
    assert.equal(await alive(sentinel.pid), true, 'a mismatched kernel start time is not ownership');
  });
});

test('a leader exiting on cleanup TERM does not strand its resistant descendant', async () => {
  await scenario('term-descendant', async ({ done, directory }) => {
    const result = await done();
    assert.equal(result.code, 0, result.output);
    const descendant = (await events(directory)).find(row => row.stage === 'term-descendant');
    assert.ok(descendant);
    assert.equal(await alive(descendant.pid), false, 'TERM leader exit must preserve descendant ownership');
  });
});

test('signal handlers remain active throughout stubborn-child teardown', async () => {
  await scenario('teardown', async ({ runner, stage, done }) => {
    await stage('terminating');
    runner.kill('SIGTERM');
    runner.kill('SIGINT');
    const result = await done();
    assert.equal(result.signal, null, result.output);
    assert.equal(JSON.parse(await readFile(`${result.runDirectory}/cleanup.json`, 'utf8')).databaseRemoved, true);
  });
});

for (const name of ['smoke-interrupt', 'smoke-close-error']) {
  test(`${name} leaves no plaintext password or worker-secret artifacts`, async () => {
    await scenario(name, async ({ runner, stage, done }) => {
      await stage('smoke');
      if (name === 'smoke-interrupt') runner.kill('SIGTERM');
      else await stage('context-close');
      const result = await done();
      assert.equal(result.code, 1, result.output);
      const remaining = await readdir(result.runDirectory);
      assert.deepEqual(remaining.filter(name => name.startsWith('passwords-') || name === 'secrets'), [], 'outer cleanup owns secret artifacts');
      assert.equal(JSON.parse(await readFile(`${result.runDirectory}/cleanup.json`, 'utf8')).databaseRemoved, true);
    });
  });
}
