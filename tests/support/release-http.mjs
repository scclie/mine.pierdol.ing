// test-only OAuth provider and static facade.
import { createServer, request as proxyRequest } from 'node:http';
import { readFile } from 'node:fs/promises';
import { resolve, extname } from 'node:path';
import { randomBytes, createHash } from 'node:crypto';

const codes = new Map();
const tokens = new Map();
const identities = { 'player-desktop': '1001', 'player-mobile': '1002', moderator: '2001', administrator: '3001' };
const server = createServer(async (req, res) => {
  const url = new URL(req.url, 'http://localhost');
  const json = (status, value) => res.writeHead(status, { 'Content-Type': 'application/json' }).end(JSON.stringify(value));
  if (process.env.MODE === 'oauth') {
    if (url.pathname.startsWith('/identity/')) {
      const name = url.pathname.slice('/identity/'.length);
      if (!identities[name]) return res.writeHead(404).end();
      return res.writeHead(204, { 'Set-Cookie': `release_identity=${name}; Path=/; HttpOnly; SameSite=Lax` }).end();
    }
    if (url.pathname === '/authorize') {
      const name = /(?:^|;\s*)release_identity=([^;]+)/.exec(req.headers.cookie || '')?.[1];
      const callback = new URL(process.env.CALLBACK);
      if (!identities[name] || url.searchParams.get('redirect_uri') !== callback.href || url.searchParams.get('code_challenge_method') !== 'S256') return json(400, {});
      const code = randomBytes(24).toString('hex');
      codes.set(code, { id: identities[name], challenge: url.searchParams.get('code_challenge') });
      callback.searchParams.set('state', url.searchParams.get('state'));
      callback.searchParams.set('code', code);
      return res.writeHead(302, { Location: callback.href }).end();
    }
    if (url.pathname === '/token' && req.method === 'POST') {
      let body = '';
      for await (const chunk of req) { body += chunk; if (body.length > 65536) return res.writeHead(413).end(); }
      const form = new URLSearchParams(body);
      const code = codes.get(form.get('code'));
      codes.delete(form.get('code'));
      if (!code || createHash('sha256').update(form.get('code_verifier') || '').digest('base64url') !== code.challenge || form.get('redirect_uri') !== process.env.CALLBACK) return json(400, {});
      const token = randomBytes(24).toString('hex');
      tokens.set(token, code.id);
      return json(200, { access_token: token, token_type: 'Bearer' });
    }
    if (url.pathname === '/me') {
      const token = (req.headers.authorization || '').replace(/^Bearer /, '');
      const id = tokens.get(token);
      tokens.delete(token);
      return json(id ? 200 : 401, id ? { id, username: `local-${id}`, global_name: null, avatar: null } : {});
    }
    return res.writeHead(url.pathname === '/__ready' ? 200 : 404).end();
  }
  if (url.pathname.startsWith('/api/')) {
    const upstream = proxyRequest(`${process.env.API_ORIGIN}${req.url}`, { method: req.method, headers: { ...req.headers, connection: 'close' }, agent: false }, incoming => {
      res.writeHead(incoming.statusCode, incoming.headers);
      incoming.pipe(res);
    });
    upstream.on('error', () => { if (!res.headersSent) res.writeHead(502); res.end(); });
    req.pipe(upstream);
    return;
  }
  if (url.pathname === '/__ready') return res.writeHead(200).end('ready');
  const root = resolve(process.env.STATIC_ROOT || 'public');
  const path = resolve(root, `.${url.pathname}`);
  if (path !== root && !path.startsWith(`${root}/`)) return res.writeHead(403).end();
  try {
    const file = extname(path) ? path : `${path}/index.html`;
    const data = await readFile(file);
    res.writeHead(200, { 'Content-Type': ({ '.html': 'text/html', '.css': 'text/css', '.js': 'text/javascript' })[extname(file)] || 'application/octet-stream' }).end(data);
  } catch { res.writeHead(404).end(); }
});
server.listen(Number(process.env.PORT), '127.0.0.1');
for (const signal of ['SIGTERM', 'SIGINT']) process.on(signal, () => { server.closeAllConnections(); server.close(); });
