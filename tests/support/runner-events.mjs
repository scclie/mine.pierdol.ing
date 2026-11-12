import { appendFileSync, readFileSync } from 'node:fs';

export function processIdentity(pid) {
  try {
    const fields = readFileSync(`/proc/${pid}/stat`, 'utf8').split(') ')[1].split(' ');
    return { pid, born: fields[19], group: Number(fields[2]), session: Number(fields[3]), state: fields[0] };
  } catch (error) { if (error.code === 'ENOENT' || error.code === 'ESRCH') return null; throw error; }
}

export function event(stage, pid = process.pid, extra = {}) {
  const identity = processIdentity(pid);
  if (!identity) throw new Error('cannot record vanished test process');
  appendFileSync(`${process.env.CASE_DIR}/events.jsonl`, `${JSON.stringify({ stage, ...identity, ...extra })}\n`, { mode: 0o600 });
}

export function stopEvent(record) {
  if (!record) return;
  const current = processIdentity(record.pid);
  if (!current || current.born !== record.born || current.state === 'Z') return;
  const group = record.stage === 'browser-stopped';
  if (group && (current.group !== record.pid || current.session !== record.pid)) return;
  try { process.kill(group ? -record.pid : record.pid, 'SIGKILL'); }
  catch (error) { if (error.code !== 'ESRCH') throw error; }
}
