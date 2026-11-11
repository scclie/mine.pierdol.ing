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

if (document.querySelector('[data-server-id]')) updateServers();

// accept same-origin json only; never follow api redirects to login pages
export async function api(path, { method = 'GET', body, token } = {}) {
  if (!path.startsWith('/api/v1/') || path.includes('#')) throw new Error('invalid api path');
  const headers = { Accept: 'application/json' };
  if (method !== 'GET') {
    headers['Content-Type'] = 'application/json';
    headers['X-CSRF-Token'] = token;
  }
  const response = await fetch(path, {
    method, headers, credentials: 'same-origin', redirect: 'error', cache: 'no-store',
    ...(method !== 'GET' ? { body: JSON.stringify(body ?? {}) } : {}),
  });
  const payload = response.status === 204 ? null : await response.json();
  if (!response.ok) {
    const error = new Error(response.status === 401 ? 'please sign in to continue' : (payload?.error?.code || 'request failed').replaceAll('_', ' '));
    error.status = response.status;
    error.code = payload?.error?.code;
    throw error;
  }
  return payload;
}

// field errors use error.code, not html or error maps.
export function prepareForm(form) {
  for (const control of form.querySelectorAll('input[name], select[name], textarea[name]')) {
    const message = document.createElement('span');
    message.id = `${control.id}-error`;
    message.className = 'field-error';
    message.dataset.errorFor = control.name;
    control.setAttribute('aria-describedby', [control.getAttribute('aria-describedby'), message.id].filter(Boolean).join(' '));
    control.after(message);
  }
}

export function clearErrors(form, alert) {
  alert.textContent = '';
  for (const control of form.querySelectorAll('[aria-invalid]')) control.removeAttribute('aria-invalid');
  for (const message of form.querySelectorAll('[data-error-for]')) message.textContent = '';
}

export function showError(error, alert, form) {
  alert.textContent = error.message || 'request could not be completed';
  if (!form || ![409, 422].includes(error.status)) return;
  const field = [...form.elements].find((control) => control.name && (
    error.code?.includes(control.name) ||
    (control.name === 'minecraft_nickname' && error.code === 'nickname_unavailable')
  ));
  if (!field) return;
  field.setAttribute('aria-invalid', 'true');
  const message = [...form.querySelectorAll('[data-error-for]')].find((item) => item.dataset.errorFor === field.name);
  if (message) message.textContent = alert.textContent;
  field.focus();
}
