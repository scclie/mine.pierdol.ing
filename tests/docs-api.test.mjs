import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';

test('API documentation covers every registered method/path and mapped public error status', async () => {
  const docs = await readFile('docs/api-v1.md', 'utf8');
  let endpoints = 0;
  const codes = new Set();
  for (const file of ['auth', 'account', 'admin']) {
    const source = await readFile(`src/routes/${file}.zig`, 'utf8');
    for (const [, method, path] of source.matchAll(/server\.route(?:Json)?\(\.(\w+), "([^"]+)"/g)) {
      assert.ok(docs.includes(`| ${method} | \`${path}\` |`), `${method} ${path}`);
      endpoints++;
    }
    for (const [, status, code] of source.matchAll(/\.status = (\d+), \.code = "([^"]+)"/g)) {
      assert.ok(docs.includes(`| ${status} | \`${code}\` |`), `${status} ${code}`);
      codes.add(code);
    }
  }
  for (const [status, code] of [[400, 'oauth_state_invalid'], [502, 'oauth_provider_error'], [404, 'not_found'], [405, 'method_not_allowed'], [413, 'request_body_too_large'], [415, 'unsupported_media_type']]) {
    assert.ok(docs.includes(`| ${status} | \`${code}\` |`), `${status} ${code}`);
  }
  assert.equal(endpoints, 12);
  assert.ok(codes.size >= 40);
  assert.match(docs, /healthz.*404/);
  assert.match(docs, /public\/servers.*404/);
});

test('security and README state implemented limits and exact SPDX license', async () => {
  const readme = await readFile('README.md', 'utf8');
  const security = await readFile('docs/security.md', 'utf8');
  const license = await readFile('LICENSE', 'utf8');
  assert.match(readme, /AGPL-3\.0-or-later/);
  for (const term of ['PKCE', 'HttpOnly', 'SameSite=Lax', 'Argon2id', 'TOTP', 'read-only', 'redact']) assert.ok(security.includes(term), term);
  assert.match(license, /GNU AFFERO GENERAL PUBLIC LICENSE/);
  assert.match(license, /Version 3, 19 November 2007/);
  assert.match(license, /END OF TERMS AND CONDITIONS/);
  // Canonical https://www.gnu.org/licenses/agpl-3.0.txt
  assert.equal(createHash('sha256').update(license).digest('hex'), '0d96a4ff68ad6d4b6f1f30f713b18d5184912ba8dd389f86aa7710db079abcb0');
});
