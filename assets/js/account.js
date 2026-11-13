import { api, accountState, refreshAccountState, logout, prepareForm, clearErrors, showError } from './api.js';

const root = document.querySelector('[data-account]');
const alert = document.querySelector('[data-error]');
const notice = document.querySelector('[data-notice]');
let account;
let busy = false;

function cloneForm(selector) {
  const form = document.querySelector(selector).content.firstElementChild.cloneNode(true);
  prepareForm(form);
  document.querySelector('[data-controls]').append(form);
  return form;
}

function render(payload) {
  if (!payload) throw new Error('account lookup failed');
  account = payload;
  root.hidden = false;
  const username = account.user.discord_username;
  document.querySelector('[data-discord-identity]').textContent = username
    ? `@${username} (${account.user.discord_id})`
    : `discord user (${account.user.discord_id})`;
  const application = account.application;
  const state = document.querySelector('[data-account-state]');
  const status = application?.status || 'no application';
  state.textContent = status;
  if (application) state.dataset.status = application.status;
  else delete state.dataset.status;
  document.querySelector('[data-nickname-row]').hidden = !application;
  document.querySelector('[data-nickname]').textContent = application?.minecraft_nickname || '';
  document.querySelector('[data-reason-row]').hidden = application?.decision_reason == null;
  document.querySelector('[data-decision-reason]').textContent = application?.decision_reason ?? '';
  document.querySelector('[data-password-setup]').hidden = !account.password_setup_required;
  document.querySelector('[data-controls]').replaceChildren();
  if (account.actions.can_submit || account.actions.can_resubmit) applicationForm(application);
  if (account.actions.can_change_password) passwordForm();
}

async function mutationError(error, form) {
  if (error.code === 'csrf_token_invalid') {
    try {
      const current = await refreshAccountState();
      if (current) render(current);
    } catch {
      // keep mutation error if refresh fails.
    }
  }
  showError(error, alert, form);
}

function applicationForm(application) {
  const form = cloneForm('[data-application-form]');
  const fields = form.elements;
  const submit = form.querySelector('[type=submit]');
  submit.textContent = account.actions.can_resubmit ? 'resubmit application' : 'submit application';
  fields.minecraft_nickname.value = application?.minecraft_nickname || '';
  fields.minecraft_nickname.readOnly = Boolean(application);
  fields.client_type.value = application?.client_type || 'licensed';
  const togglePassword = () => {
    const cracked = fields.client_type.value === 'cracked';
    form.querySelector('[data-password-field]').hidden = !cracked;
    fields.password.disabled = !cracked;
    fields.password.required = cracked;
    if (!cracked) fields.password.value = '';
  };
  fields.client_type.addEventListener('change', togglePassword);
  togglePassword();
  form.addEventListener('submit', async (event) => {
    event.preventDefault();
    if (busy) return;
    clearErrors(form, alert);
    notice.textContent = '';
    const body = Object.fromEntries(new FormData(form));
    // omit the key entirely for licensed requests, even if empty
    if (fields.client_type.value === 'licensed') delete body.password;
    fields.password.value = '';
    busy = true;
    submit.disabled = true;
    try {
      await api('/api/v1/account/application', { method: account.actions.can_resubmit ? 'PATCH' : 'POST', body, token: account.csrf_token });
      render(await refreshAccountState());
      notice.textContent = 'application submitted';
    } catch (error) {
      await mutationError(error, form);
    } finally {
      busy = false;
      submit.disabled = false;
    }
  });
}

function passwordForm() {
  const form = cloneForm('[data-password-form]');
  const submit = form.querySelector('button');
  form.addEventListener('submit', async (event) => {
    event.preventDefault();
    if (busy) return;
    clearErrors(form, alert);
    notice.textContent = '';
    const body = { password: form.elements.password.value };
    form.elements.password.value = '';
    busy = true;
    submit.disabled = true;
    try {
      await api('/api/v1/account/password', { method: 'POST', body, token: account.csrf_token });
      // 204 consumes the token, reload the account before the next mutation.
      render(await refreshAccountState());
      notice.textContent = 'password saved';
    } catch (error) {
      await mutationError(error, form);
    } finally {
      busy = false;
      submit.disabled = false;
    }
  });
}

document.querySelector('[data-logout]').addEventListener('click', async (event) => {
  if (busy) return;
  busy = true;
  event.currentTarget.disabled = true;
  alert.textContent = '';
  try {
    const current = await accountState();
    if (!current) throw new Error('account lookup failed');
    await logout(current.csrf_token);
    location.assign('/login');
  } catch (error) {
    showError(error, alert);
    busy = false;
    document.querySelector('[data-logout]').disabled = false;
  }
});

try {
  const current = await accountState();
  if (!current) throw new Error('account lookup failed');
  render(current);
} catch (error) {
  showError(error, alert);
} finally {
  notice.textContent = '';
}
