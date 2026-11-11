// show known servers with valid status, fallback for missing data.
function validServers(payload) {
  if (!payload || !Array.isArray(payload.servers)) return false;
  const ids = new Set();
  return payload.servers.every((server) => {
    if (!server || typeof server.id !== 'string' || !server.id || ids.has(server.id)) return false;
    if (!['planned', 'offline', 'online'].includes(server.status)) return false;
    if (server.online !== null && (!Number.isSafeInteger(server.online) || server.online < 0)) return false;
    ids.add(server.id);
    return true;
  });
}

async function updateServers() {
  try {
    const response = await fetch('/api/v1/public/servers', {
      credentials: 'same-origin',
      headers: { Accept: 'application/json' },
      redirect: 'error',
    });
    if (!response.ok || !response.headers.get('content-type')?.includes('application/json')) return;
    const payload = await response.json();
    if (!validServers(payload)) return;

    for (const card of document.querySelectorAll('[data-server-id]')) {
      const server = payload.servers.find((item) => item.id === card.dataset.serverId);
      if (!server) continue;
      const status = card.querySelector('[data-server-status]');
      const online = card.querySelector('[data-server-online]');
      status.textContent = server.status;
      status.dataset.state = server.status;
      online.textContent = server.online === null
        ? (server.status === 'planned' ? 'offline · not launched' : 'online count unavailable')
        : `${server.online} ${server.online === 1 ? 'player' : 'players'} online`;
    }
  } catch {
    // preserve server-rendered planned state on network or json errors
  }
}

updateServers();
