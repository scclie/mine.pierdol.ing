import test from 'node:test';
import assert from 'node:assert/strict';
import { buildCommitFrom, injectBuildCommit } from '../scripts/build-commit.mjs';

const sha1 = '0123456789abcdef0123456789abcdef01234567';
const sha256 = 'abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789';

test('uses the first eight characters of a CI Git SHA', () => {
  assert.equal(buildCommitFrom({ GITHUB_SHA: sha1 }), '01234567');
  assert.equal(buildCommitFrom({ GITHUB_SHA: sha256 }), 'abcdef01');
  assert.equal(buildCommitFrom({ GITHUB_SHA: sha256.toUpperCase() }), 'ABCDEF01');
});

test('uses development outside a valid CI checkout', () => {
  for (const GITHUB_SHA of [undefined, '', 'not-a-commit', '01234567', `${sha1}\n`, ` ${sha1}`, 'g'.repeat(40), 'a'.repeat(41), 'a'.repeat(63)]) {
    assert.equal(buildCommitFrom({ GITHUB_SHA }), 'development');
  }
  assert.equal(buildCommitFrom({}), 'development');
});

test('injects every staged footer token and rejects a missing token', () => {
  assert.equal(injectBuildCommit('<span>BUILD_COMMIT</span>', '01234567'), '<span>01234567</span>');
  assert.equal(injectBuildCommit('BUILD_COMMIT BUILD_COMMIT', '01234567'), '01234567 01234567');
  assert.throws(() => injectBuildCommit('<span>no token</span>', '01234567'), /BUILD_COMMIT/);
});
