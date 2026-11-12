// Shared local verification lifecycle. Never consumes DATABASE_URL from the caller.
import { spawn } from 'node:child_process';
import { mkdir, mkdtemp, chmod, open, rm, writeFile } from 'node:fs/promises';
import { setTimeout as delay } from 'node:timers/promises';
import { createServer } from 'node:net';
import { appendFileSync, readFileSync, readdirSync, realpathSync, statSync } from 'node:fs';
import { dirname, isAbsolute } from 'node:path';
import { fileURLToPath } from 'node:url';

// Nested verification subprocesses may themselves start detached groups. Only
// accept private registries owned by actual ancestors, never caller-chosen PIDs.
function ancestorRegistries() {
  const ancestors = new Set();
  let pid = process.ppid;
  while (pid > 1) {
    ancestors.add(pid);
    try { pid = Number(readFileSync(`/proc/${pid}/stat`, 'utf8').split(') ')[1].split(' ')[1]); }
    catch { break; }
  }
  try {
    const files = JSON.parse(process.env.TASK12_GROUP_REGISTRIES || '[]');
    if (!Array.isArray(files)) return [];
    return files.filter(file => {
      if (typeof file !== 'string') return false;
      const match = file.match(/^\/tmp\/opencode\/task12-fix-2\/.+\/groups-(\d+)\.jsonl$/);
      if (!match || !ancestors.has(Number(match[1]))) return false;
      try {
        const stat = statSync(file);
        return realpathSync(file) === file && stat.isFile() && stat.uid === process.getuid() && (stat.mode & 0o077) === 0;
      } catch { return false; }
    });
  } catch { return []; }
}

function identity(pid) {
  try {
    const fields = readFileSync(`/proc/${pid}/stat`, 'utf8').split(') ')[1].split(' ');
    return { pid, state: fields[0], group: Number(fields[2]), session: Number(fields[3]), born: fields[19] };
  } catch (error) { if (error.code === 'ENOENT' || error.code === 'ESRCH') return null; throw error; }
}

function groupMembers(pid) {
  return readdirSync('/proc').filter(name => /^\d+$/.test(name)).map(name => identity(Number(name)))
    .filter(member => member && member.group === pid && member.session === pid && member.state !== 'Z');
}

// Called by the browser supervisor inside Playwright's detached session.
// Publish BEFORE browser startup and again before the supervisor exits, so a
// surviving descendant still pins ownership after the leader disappears.
export function registerBrowserGroup() {
  const leader = identity(process.pid);
  const registries = ancestorRegistries();
  if (!registries.length || !leader || leader.group !== leader.pid || leader.session !== leader.pid) {
    throw new Error('browser launch requires a verified local lifecycle owner');
  }
  // Establish authority while ancestry is known, then retain those exact private
  // registry identities. Playwright's abrupt exit can reparent this supervisor;
  // that must not revoke the outer owner's already established registration.
  const authority = registries.map(file => ({ file, stat: statSync(file) }));
  const register = () => {
    const current = identity(process.pid);
    if (!current || current.born !== leader.born || current.group !== leader.pid || current.session !== leader.pid) {
      throw new Error('browser supervisor lost its verified session');
    }
    const group = { pid: leader.pid, born: leader.born, members: groupMembers(leader.pid) };
    for (const { file, stat } of authority) {
      const now = statSync(file);
      if (realpathSync(file) !== file || !now.isFile() || now.ino !== stat.ino || now.dev !== stat.dev || now.uid !== stat.uid || (now.mode & 0o077)) {
        throw new Error('browser registry identity changed');
      }
      appendFileSync(file, `${JSON.stringify(group)}\n`, { mode: 0o600 });
    }
  };
  register();
  return register;
}

export async function localRun(label, run) {
  process.umask(0o077);
  await mkdir('/tmp/opencode/task12-fix-2', { recursive: true, mode: 0o700 });
  const inheritedRegistries = ancestorRegistries();
  // outer secret cleanup also owns any abruptly abandoned nested run state.
  const base = inheritedRegistries.length ? `${dirname(inheritedRegistries.at(-1))}/secrets` : '/tmp/opencode/task12-fix-2';
  const directory = await mkdtemp(`${base}/${label}-`);
  await chmod(directory, 0o700);
  const registry = `${directory}/groups-${process.pid}.jsonl`;
  const registries = [...inheritedRegistries, registry];
  const children = [];
  const handles = [];
  const pendingStarts = new Set();
  const finalizers = [];
  const controller = new AbortController();
  let closing = false;
  const interrupted = new Promise((_, reject) => {
    controller.signal.addEventListener('abort', () => reject(controller.signal.reason), { once: true });
  });
  // signals can arrive during initdb/readiness, before the callback is reached.
  interrupted.catch(() => {});
  const race = promise => Promise.race([promise, interrupted]);
  const checkOpen = () => {
    if (closing) throw controller.signal.reason || new Error('verification lifecycle closed');
  };
  // libpq combines URI parameters with environment defaults (hostaddr overrides a URI's host). Discard *all* inherited PG settings, including future ones.
  const env = { ...Object.fromEntries(Object.entries(process.env).filter(([key]) => !key.startsWith('PG'))),
    TMPDIR: `${directory}/secrets`, PGHOST: directory, PGUSER: 'postgres', PGDATABASE: 'postgres', PGPORT: '5432',
    DATABASE_URL: '', TEST_DATABASE_URL: '', PGPASSFILE: `${directory}/secrets/pgpass`, PGSERVICEFILE: '/dev/null',
    TASK12_GROUP_REGISTRIES: JSON.stringify(registries), TASK12_SECRET_FILE: `${directory}/secrets/password-redactions.jsonl` };
  function start(command, args, extra = {}, log) {
    const operation = (async () => {
      checkOpen();
      const handle = log ? await open(`${directory}/${log}`, 'a', 0o600) : null;
      if (handle) handles.push(handle);
      checkOpen();
      const child = spawn(command, args, { env: { ...env, ...extra }, detached: true, stdio: handle ? ['ignore', handle.fd, handle.fd] : 'inherit' });
      const recordGroup = () => {
        if (!child.pid) return;
        const leader = identity(child.pid);
        if (child.group?.born && leader && leader.born !== child.group.born) return;
        child.group = { pid: child.pid, born: child.group?.born || leader?.born,
          members: [...(child.group?.members || []), ...groupMembers(child.pid)] };
        for (const file of registries) appendFileSync(file, `${JSON.stringify(child.group)}\n`, { mode: 0o600 });
      };
      child.done = new Promise((resolve, reject) => {
        child.once('error', reject);
        child.once('exit', (code, signal) => {
          // preserve descendant identities when the leader exits before cleanup.
          try { recordGroup(); resolve({ code, signal }); } catch (error) { reject(error); }
        });
      });
      child.done.catch(() => {});
      child.done.then(() => { child.finished = true; }, () => { child.finished = true; });
      children.push(child);
      recordGroup();
      return child;
    });
    const pending = operation();
    pendingStarts.add(pending);
    pending.then(() => pendingStarts.delete(pending), () => pendingStarts.delete(pending));
    return pending;
  }
  async function command(command, args, extra) {
    const child = await start(command, args, extra);
    const result = await race(child.done);
    if (result.code !== 0) throw new Error(`${command} failed (${result.code ?? result.signal})`);
  }
  const ready = (check, child) => race(wait(check, child, controller.signal));
  const ownBrowser = async executable => {
    checkOpen();
    if (typeof executable !== 'string' || !isAbsolute(executable)) throw new Error('absolute browser executable required');
    const wrapper = `${directory}/secrets/browser-launch`;
    await writeFile(wrapper, `#!${process.execPath}\nimport { superviseBrowser } from ${JSON.stringify(fileURLToPath(new URL('./register-browser.mjs', import.meta.url)))};\nawait superviseBrowser(${JSON.stringify(executable)});\n`, { mode: 0o700, flag: 'wx' });
    checkOpen();
    return wrapper;
  };
  const interrupt = () => {
    closing = true;
    controller.abort(new Error('verification interrupted'));
  };
  process.on('SIGINT', interrupt);
  process.on('SIGTERM', interrupt);
  try {
    console.log(`Local verification artifacts: ${directory}`);
    await writeFile(registry, '', { mode: 0o600, flag: 'wx' });
    await mkdir(env.TMPDIR, { mode: 0o700 });
    // use a private empty file to avoid ~/.pgpass and libpq warnings.
    // never store plaintext credentials in it.
    await writeFile(env.PGPASSFILE, '', { mode: 0o600, flag: 'wx' });
    await race((async () => {
      await command('initdb', ['-D', `${directory}/pg`, '-U', 'postgres', '-A', 'trust', '--no-locale', '--encoding=UTF8']);
      const postgres = await start('postgres', ['-D', `${directory}/pg`, '-k', directory, '-h', '', '-p', '5432', '-c', 'log_statement=none', '-c', 'log_min_error_statement=panic'], {}, 'postgres.log');
      await ready(async () => {
        const probe = await start('pg_isready', ['-q']);
        return (await race(probe.done)).code === 0;
      }, postgres);
      const database = `postgresql:///postgres?host=${directory}&user=postgres&port=5432`;
      env.TEST_DATABASE_URL = database;
      await run({ directory, database, env, start, command, wait: ready, ownBrowser,
        afterStop: action => { checkOpen(); finalizers.push(action); }, signal: controller.signal });
    })());
  } finally {
    closing = true;
    controller.abort(new Error('verification lifecycle closed'));
    const errors = [];
    const attempt = async action => { try { await action(); } catch (error) { errors.push(error); } };
    let databaseRemoved = false;
    let secretsRemoved = false;
    let groupsGone = false;
    try {
      await Promise.allSettled([...pendingStarts]);
      // track ownership by process group, even after the leader exits.
      // register browser sessions before exec.
      const groups = new Map();
      const retired = new Set();
      const seen = new Set();
      const recordedGroups = () => readFileSync(registry, 'utf8').trim().split('\n').filter(Boolean).map(line => JSON.parse(line));
      const kill = (pid, signal) => {
        if (retired.has(pid)) return false;
        const group = groups.get(pid);
        const leader = identity(pid);
        // reused pids or sessions do not prove ownership.
        // verify a recorded member's start time, even after the leader exits.
        const ownsMember = () => (!leader || !group.born || leader.born === group.born) && group.members.some(member => {
          const current = identity(member.pid);
          return current && current.born === member.born && current.group === pid && current.session === pid && current.state !== 'Z';
        });
        let owned = ownsMember();
        if (!owned && (!leader || leader.born === group.born) && groupMembers(pid).length) {
          // reconcile the supervisor's final snapshot before retirement.
          // never treat a live, unverified session as gone.
          for (const update of recordedGroups()) {
            if (update.pid === pid && update.born === group.born && Array.isArray(update.members)) group.members.push(...update.members);
          }
          owned = ownsMember();
          if (!owned && groupMembers(pid).length) throw new Error('remaining process group ownership unavailable; scratch preserved');
        }
        if (owned) {
          // snapshot child processes while the session is still verified.
          // TERM may end the leader before node handles its exit.
          group.members = [...new Map([...group.members, ...groupMembers(pid)]
            .map(member => [`${member.pid}:${member.born}`, member])).values()];
          try { process.kill(-pid, signal); return true; }
          catch (error) { if (error.code !== 'ESRCH') throw error; }
        } else if (children.some(child => child.pid === pid && !child.finished)) {
          // never signal unverified ids.
          // wait for the final descendant snapshot before releasing ownership.
          return true;
        }
        retired.add(pid);
        groups.delete(pid);
        return false;
      };
      const discover = () => {
        const recorded = recordedGroups();
        for (const group of [...children.toReversed().map(child => child.group).filter(Boolean), ...recorded]) {
          const { pid, members } = group;
          if (!Number.isSafeInteger(pid) || pid <= 1 || !Array.isArray(members)) throw new Error('invalid owned process group');
          if (retired.has(pid)) continue;
          const previous = groups.get(pid);
          groups.set(pid, { ...group, members: [...(previous?.members || []), ...members] });
          seen.add(pid);
        }
        // merge all identity updates before marking a group as gone.
        // earlier registry entries may miss surviving child processes.
        for (const pid of groups.keys()) if (!signaled.has(pid)) { signaled.add(pid); kill(pid, 'SIGTERM'); }
      };
      const signaled = new Set();
      await attempt(discover);
      await attempt(async () => {
        const deadline = Date.now() + 3000;
        while (Date.now() < deadline) {
          discover();
          if (![...groups.keys()].map(pid => kill(pid, 0)).some(Boolean)) break;
          await delay(20);
        }
      });
      await attempt(discover);
      for (const pid of groups.keys()) await attempt(() => kill(pid, 'SIGKILL'));
      await Promise.allSettled(children.map(child => child.done));
      await attempt(async () => {
        const deadline = Date.now() + 3000;
        do {
          discover();
          const remaining = [...groups.keys()].filter(pid => kill(pid, 0));
          if (!remaining.length) { groupsGone = true; return; }
          for (const pid of remaining) kill(pid, 'SIGKILL');
          await delay(20);
        } while (Date.now() < deadline);
        throw new Error('owned process groups did not terminate; scratch preserved');
      });
      for (const handle of handles) await attempt(() => handle.close());
      if (groupsGone) for (const finalize of finalizers) await attempt(finalize);
      // workers are stopped first; neither browser teardown nor another cleanup
      // error may prevent removal of database state and browser/worker scratch.
      if (groupsGone) {
        await attempt(async () => { await rm(`${directory}/pg`, { recursive: true, force: true }); databaseRemoved = true; });
        await attempt(async () => { await rm(`${directory}/secrets`, { recursive: true, force: true }); secretsRemoved = true; });
      }
      await attempt(() => writeFile(`${directory}/cleanup.json`, JSON.stringify({
        children: children.filter(c => c.pid).map(c => ({ pid: c.pid, code: c.exitCode, signal: c.signalCode })),
        groups: [...seen], retiredGroups: [...retired],
        groupsGone, databaseRemoved, secretsRemoved, cleanupErrors: errors.map(error => error.code || error.name),
      }, null, 2), { mode: 0o600 }));
      if (errors.length) throw new AggregateError(errors, 'local verification cleanup failed');
      console.log(`Cleaned local child processes, disposable database and secret scratch: ${directory}`);
    } finally {
      // Repeated catchable signals must not interrupt asynchronous teardown.
      process.off('SIGINT', interrupt);
      process.off('SIGTERM', interrupt);
    }
  }
}

export async function wait(check, child, signal) {
  for (let i = 0; i < 200; i++) {
    signal?.throwIfAborted();
    if (child && (child.exitCode !== null || child.signalCode !== null)) throw new Error('local service exited before readiness');
    try { if (await check()) return; } catch {}
    await delay(50, undefined, { signal });
  }
  throw new Error('local service readiness timed out');
}

export async function freshPort() {
  const server = createServer();
  await new Promise((resolve, reject) => { server.once('error', reject); server.listen(0, '127.0.0.1', resolve); });
  const port = server.address().port;
  await new Promise(resolve => server.close(resolve));
  if (port === 3099) return freshPort();
  return port;
}

export function zigArgs(directory) {
  return ['-j2', '--cache-dir', `${directory}/zig-cache`, '--global-cache-dir', `${directory}/zig-global`, '--prefix', `${directory}/zig-out`, '--summary', 'all',
    ...(process.env.TASK12_ZIG_PREFIXES || '').split(':').filter(Boolean).flatMap(path => ['--search-prefix', path])];
}
