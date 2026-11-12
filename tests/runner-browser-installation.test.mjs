import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { access, mkdir, mkdtemp, rm } from 'node:fs/promises';
import { constants } from 'node:fs';
import { chromium } from '@playwright/test';

const override = process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH;
const bundled = await access(chromium.executablePath(), constants.X_OK).then(() => true, () => false);
async function safety(env, args = []) {
  delete env.NODE_TEST_CONTEXT;
  const child = spawn(process.execPath, ['--test', '--test-reporter=tap', ...args, 'tests/runner-safety.test.mjs'], {
    env, stdio: ['ignore', 'pipe', 'pipe'],
  });
  let output = '';
  child.stdout.on('data', data => { output += data; });
  child.stderr.on('data', data => { output += data; });
  const code = await new Promise((resolve, reject) => {
    child.once('error', reject);
    child.once('exit', resolve);
  });
  assert.equal(code, 0, output);
  return output;
}

test('override-only installation passes every mandatory release safety case without a bundle', { skip: !override && 'requires an explicit Chromium override' }, async () => {
  await mkdir('/tmp/opencode/task12-fix-4', { recursive: true, mode: 0o700 });
  const directory = await mkdtemp('/tmp/opencode/task12-fix-4/no-bundle-');
  try {
    const output = await safety({ ...process.env, PLAYWRIGHT_BROWSERS_PATH: directory });
    assert.match(output, /# pass 20\b/);
    assert.match(output, /# skipped 1\b/);
    assert.match(output, /unset Chromium override.*# SKIP/);
  } finally { await rm(directory, { recursive: true, force: true }); }
});

test('provisioned bundle runs the real unset-override resistant-browser fallback', { skip: !bundled && 'requires compatible bundled Chromium' }, async () => {
  const env = { ...process.env };
  delete env.PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH;
  const output = await safety(env, ['--test-name-pattern=unset Chromium override']);
  assert.match(output, /# pass 1\b/);
  assert.doesNotMatch(output, /unset Chromium override[^\n]*# SKIP/);
});
