import { appendFileSync, readFileSync } from 'node:fs';

// use the registry only for temporary secrets, never as evidence.
// register before browser/api calls to redact even failed steps.
export function registerPasswords(passwords) {
  if (!process.env.TASK12_SECRET_FILE) throw new Error('secret-owned runner required');
  for (const password of passwords) appendFileSync(process.env.TASK12_SECRET_FILE, `${JSON.stringify(password)}\n`, { mode: 0o600 });
}

export function readPasswords(file = process.env.TASK12_SECRET_FILE) {
  try { return readFileSync(file, 'utf8').trim().split('\n').filter(Boolean).map(line => JSON.parse(line)); }
  catch (error) { if (error.code === 'ENOENT') return []; throw error; }
}

export function redact(text, passwords = readPasswords()) {
  for (const password of passwords) text = text.replaceAll(password, '[REDACTED]');
  return text;
}

export function redactValue(value) {
  if (typeof value === 'string') return redact(value);
  if (Array.isArray(value)) return value.map(redactValue);
  if (value && typeof value === 'object') return Object.fromEntries(Object.entries(value).map(([key, item]) => [redact(key), redactValue(item)]));
  return value;
}
