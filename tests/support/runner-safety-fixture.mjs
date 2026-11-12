// disable startup commands so RED never connects to a real database.
import { mkdirSync } from 'node:fs';
import { basename } from 'node:path';
import { event as recordEvent } from './runner-events.mjs';

const command = basename(process.argv[1]);
const event = stage => recordEvent(stage, process.pid, { pg: Object.fromEntries(Object.entries(process.env).filter(([key]) => key.startsWith('PG'))) });
event(command);
if (command === 'initdb') mkdirSync(`${process.env.PGHOST}/pg`, { recursive: true });
if ((command === 'initdb' && process.env.SCENARIO === 'initialization') ||
    (command === 'pg_isready' && process.env.SCENARIO === 'readiness')) {
  event('blocked');
  setInterval(() => {}, 1000);
} else if (command === 'postgres') {
  setInterval(() => {}, 1000);
}
