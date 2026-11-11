// Test-only server: no API, database, proxy, or SPA fallback.
import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { resolve, extname } from 'node:path';

const root = resolve('public');
const types = { '.html': 'text/html', '.css': 'text/css', '.js': 'text/javascript' };
const server = createServer(async (request, response) => {
  const pathname = new URL(request.url, 'http://localhost').pathname;
  if (pathname === '/__ready') {
    response.writeHead(200).end('ready');
    return;
  }
  const path = resolve(root, `.${pathname}`);
  if (path !== root && !path.startsWith(`${root}/`)) {
    response.writeHead(403).end();
    return;
  }
  for (const candidate of extname(path) ? [path] : [`${path}/index.html`]) {
    try {
      const body = await readFile(candidate);
      response.writeHead(200, { 'Content-Type': `${types[extname(candidate)] || 'application/octet-stream'}; charset=utf-8` }).end(body);
      return;
    } catch (error) {
      if (!['ENOENT', 'ENOTDIR'].includes(error.code)) throw error;
    }
  }
  response.writeHead(404, { 'Content-Type': 'text/html; charset=utf-8' }).end('<!doctype html><title>Not found</title><p>Not found</p>');
});
server.listen(Number(process.env.PORT || 3099), '127.0.0.1');
for (const signal of ['SIGINT', 'SIGTERM']) process.on(signal, () => server.close());
