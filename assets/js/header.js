import { accountState, logout } from './api.js';

const auth = document.querySelector('[data-header-auth]');
const login = document.querySelector('[data-header-login]');
const moderation = document.querySelector('[data-header-moderation]');

function accountLabel(account) {
  return account.application?.minecraft_nickname || 'account';
}

function renderAuthenticatedHeader(account) {
  const showModeration = ['moderator', 'administrator'].includes(account.user.role);
  const link = document.createElement('a');
  link.className = 'header-account-link';
  link.href = '/account';
  link.textContent = accountLabel(account);

  const application = account.application;
  if (application?.client_type === 'licensed' && application.minecraft_nickname) {
    const avatar = document.createElement('img');
    avatar.className = 'minecraft-head';
    avatar.src = `https://mc-heads.net/avatar/${encodeURIComponent(application.minecraft_nickname)}/32`;
    avatar.width = 32;
    avatar.height = 32;
    avatar.alt = '';
    avatar.setAttribute('aria-hidden', 'true');
    avatar.referrerPolicy = 'no-referrer';
    avatar.addEventListener('error', () => avatar.remove(), { once: true });
    link.prepend(avatar);
  }

  const signOut = document.createElement('button');
  signOut.type = 'button';
  signOut.className = 'header-logout';
  signOut.textContent = 'sign out';
  const error = document.createElement('span');
  error.className = 'header-logout-error';
  error.setAttribute('role', 'alert');
  error.setAttribute('aria-atomic', 'true');
  signOut.addEventListener('click', async () => {
    error.textContent = '';
    signOut.disabled = true;
    try {
      const current = await accountState();
      if (!current) throw new Error('account lookup failed');
      await logout(current.csrf_token);
      location.assign('/login');
    } catch {
      error.textContent = 'Sign out failed. Please try again.';
      signOut.disabled = false;
    }
  });
  // Finish constructing the replacement before touching the guest controls.
  auth.replaceChildren(link, signOut, error);

  moderation.hidden = !showModeration;
}

async function initHeader() {
  if (!auth || !login || !moderation) return;
  try {
    const account = await accountState();
    if (!account || typeof account.user?.role !== 'string') return;
    renderAuthenticatedHeader(account);
  } catch {
    // Preserve the static guest controls on account lookup errors.
  }
}

initHeader();
