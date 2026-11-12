import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:net';
import { readFile } from 'node:fs/promises';
import { localRun } from '../scripts/test-local.mjs';

test('hostile libpq defaults cannot redirect real probes or psql from the private cluster', async () => {
  let connections = 0;
  const canary = createServer(socket => { connections++; socket.destroy(); });
  await new Promise((resolve, reject) => {
    canary.once('error', reject);
    canary.listen(0, '127.0.0.1', resolve);
  });
  const inherited = {
    PGHOSTADDR: '127.0.0.1', PGPORT: String(canary.address().port), PGHOST: 'not-a-socket',
    PGPASSFILE: '/tmp/opencode/task12-fix-2/must-not-read-passfile', PGSERVICE: 'hostile',
    PGSERVICEFILE: '/tmp/opencode/task12-fix-2/must-not-read-service', PGOPTIONS: '-c search_path=hostile',
    PGSSLMODE: 'require', PGTARGETSESSIONATTRS: 'standby', PGFUTURESETTING: 'hostile',
    DATABASE_URL: `postgresql://127.0.0.1:${canary.address().port}/not-ours`,
    TEST_DATABASE_URL: `postgresql://127.0.0.1:${canary.address().port}/not-ours`,
  };
  const previous = Object.fromEntries(Object.keys(inherited).map(key => [key, process.env[key]]));
  Object.assign(process.env, inherited);
  let runDirectory;
  try {
    await localRun('socket-proof', async ({ directory, database, env, start }) => {
      runDirectory = directory;
      assert.equal(env.PGHOSTADDR, undefined);
      assert.equal(env.PGPASSFILE, `${directory}/secrets/pgpass`);
      assert.equal(await readFile(env.PGPASSFILE, 'utf8'), '');
      assert.equal(env.PGSERVICE, undefined);
      assert.equal(env.PGFUTURESETTING, undefined);
      const client = await start('psql', [database, '-XAt', '-v', 'ON_ERROR_STOP=1', '-c',
        "SELECT json_build_object('data', current_setting('data_directory'), 'socket', current_setting('unix_socket_directories'), 'tcp', inet_server_addr())"], {}, 'socket-proof.json');
      assert.equal((await client.done).code, 0);
      assert.deepEqual(JSON.parse(await readFile(`${directory}/socket-proof.json`, 'utf8')), {
        data: `${directory}/pg`, socket: directory, tcp: null,
      });
    });
    assert.equal(connections, 0, 'hostile TCP destination must never receive a connection');
    const cleanup = JSON.parse(await readFile(`${runDirectory}/cleanup.json`, 'utf8'));
    assert.equal(cleanup.databaseRemoved, true);
    assert.equal(cleanup.secretsRemoved, true);
    assert.deepEqual(cleanup.cleanupErrors, []);
  } finally {
    for (const [key, value] of Object.entries(previous)) {
      if (value === undefined) delete process.env[key]; else process.env[key] = value;
    }
    await new Promise(resolve => canary.close(resolve));
  }
});
