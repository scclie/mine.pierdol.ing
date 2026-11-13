import { api, accountState, refreshAccountState, prepareForm, clearErrors, showError } from './api.js';

const alert = document.querySelector('[data-error]');
const notice = document.querySelector('[data-notice]');
const panel = document.querySelector('[data-admin]');
const filter = document.querySelector('[data-filter]');
const card = document.querySelector('[data-card]');
const next = document.querySelector('[data-next]');
let actor;
let nextCursor = null;
let currentCursor = null;
let filters = new URLSearchParams({ status: 'pending', limit: '25' });
let busy = false;

function setBusy(value) {
  busy = value;
  panel.inert = value;
  panel.setAttribute('aria-busy', String(value));
}

async function queue(cursor = null) {
  const params = new URLSearchParams(filters);
  if (cursor) params.set('cursor', cursor);
  const payload = await api(`/api/v1/admin/applications?${params}`);
  currentCursor = cursor;
  nextCursor = payload.next_cursor;
  next.disabled = !nextCursor;
  document.querySelector('[data-first]').disabled = !cursor;
  const list = document.querySelector('[data-queue]');
  list.replaceChildren();
  document.querySelector('[data-empty]').hidden = payload.applications.length !== 0;
  for (const application of payload.applications) {
    const item = document.createElement('li');
    const text = document.createElement('span');
    const identity = document.createElement('span');
    identity.textContent = `${application.minecraft_nickname} · `;
    const status = document.createElement('span');
    status.className = 'application-status';
    status.dataset.status = application.status;
    status.textContent = application.status;
    const submitted = document.createElement('span');
    submitted.textContent = ` · ${application.submitted_at}`;
    text.append(identity, status, submitted);
    const button = document.createElement('button');
    button.type = 'button';
    button.textContent = `review ${application.minecraft_nickname}`;
    button.addEventListener('click', async () => {
      if (await run(() => review(application.user_id))) card.focus();
    });
    item.append(text, button);
    list.append(item);
  }
}

function formFrom(selector, target) {
  const form = document.querySelector(selector).content.firstElementChild.cloneNode(true);
  prepareForm(form);
  document.querySelector(target).append(form);
  return form;
}

async function review(id) {
  const payload = await api(`/api/v1/admin/users/${id}`);
  const application = payload.application;
  card.hidden = false;
  document.querySelector('[data-card-title]').textContent = application?.minecraft_nickname || payload.user.discord_username;
  const details = document.querySelector('[data-card-details]');
  details.replaceChildren();
  const values = { 'user id': payload.user.id, 'discord id': payload.user.discord_id, 'discord username': payload.user.discord_username, ...(application || {}), 'password setup required': payload.password_setup_required ? 'yes' : 'no' };
  for (const [key, value] of Object.entries(values)) {
    if (value == null) continue;
    const row = document.createElement('div');
    const term = document.createElement('dt');
    const description = document.createElement('dd');
    term.textContent = key.replaceAll('_', ' ');
    description.textContent = value;
    description.className = 'literal-text';
    if (key === 'status') {
      description.classList.add('application-status');
      description.dataset.status = value;
    }
    row.append(term, description);
    details.append(row);
  }
  document.querySelector('[data-review-controls]').replaceChildren();
  document.querySelector('[data-editor]').replaceChildren();
  const readOnly = ['banned', 'rejected_final'].includes(actor.application?.status);
  if (readOnly) return;
  if (application?.status === 'pending') decisionForm(id, application);
  if (actor.user.role === 'administrator') editForm(id, payload);
}

async function mutate(id, path, method, body) {
  try {
    await api(path, { method, body, token: actor.csrf_token });
  } catch (error) {
    if (error.code === 'csrf_token_invalid') {
      try {
        const current = await refreshAccountState();
        if (current) {
          actor = current;
          if (!['moderator', 'administrator'].includes(actor.user.role)) panel.hidden = true;
        }
      } catch {
        // keep orig mutation error if refresh fails.
      }
    }
    throw error;
  }
  // consume csrf on every successful admin change
  // refresh controls if permissions have changed
  card.hidden = true;
  actor = await refreshAccountState();
  if (!actor || !['moderator', 'administrator'].includes(actor.user.role)) {
    panel.hidden = true;
    throw new Error('moderator or administrator access required');
  }
  await queue(currentCursor);
  await review(id);
  notice.textContent = 'changes saved';
}

function decisionForm(id, application) {
  const form = formFrom('[data-decision-form]', '[data-review-controls]');
  const reason = form.elements.reason;
  const gate = () => {
    for (const button of form.querySelectorAll('button[value="retryable"], button[value="final"]')) button.disabled = !reason.value.trim();
  };
  reason.addEventListener('input', gate);
  gate();
  form.addEventListener('submit', (event) => {
    event.preventDefault();
    if (busy) return;
    const kind = event.submitter?.value;
    if (!['approve', 'retryable', 'final'].includes(kind)) return;
    if (kind !== 'approve' && !reason.value.trim()) return;
    const status = kind === 'approve' ? 'approved' : `rejected_${kind}`;
    if (!confirm(`change ${application.minecraft_nickname} to ${status}?`)) return;
    const body = kind === 'approve' ? {} : { kind, reason: reason.value.trim() };
    run(() => mutate(id, `/api/v1/admin/applications/${id}/${kind === 'approve' ? 'approve' : 'reject'}`, 'POST', body), form);
  });
}

function editForm(id, payload) {
  const form = formFrom('[data-edit-form]', '[data-editor]');
  const original = { discord_id: payload.user.discord_id, minecraft_nickname: payload.application?.minecraft_nickname, client_type: payload.application?.client_type, status: payload.application?.status };
  for (const [name, value] of Object.entries(original)) {
    form.elements[name].value = value || '';
    form.elements[name].disabled = value == null;
  }
  const needsReason = () => original.status !== form.elements.status.value && ['banned', 'rejected_retryable', 'rejected_final'].includes(form.elements.status.value);
  const gate = () => { form.elements.reason.required = needsReason(); };
  form.elements.status.addEventListener('change', gate);
  gate();
  form.addEventListener('submit', (event) => {
    event.preventDefault();
    if (busy) return;
    clearErrors(form, alert);
    const body = {};
    for (const [key, value] of Object.entries(original)) {
      if (value != null && form.elements[key].value.trim() !== value) body[key] = form.elements[key].value.trim();
    }
    if (!Object.keys(body).length) { notice.textContent = 'no changes to save'; return; }
    if (needsReason() && !form.elements.reason.value.trim()) {
      showError({ message: 'reason required', code: 'reason_required', status: 422 }, alert, form);
      return;
    }
    if (form.elements.reason.value.trim()) body.reason = form.elements.reason.value.trim();
    if (body.status && !confirm(`change ${original.minecraft_nickname}${body.minecraft_nickname ? ` (${body.minecraft_nickname})` : ''} to ${body.status}?`)) return;
    run(() => mutate(id, `/api/v1/admin/users/${id}`, 'PATCH', body), form);
  });
}

async function run(action, form) {
  if (busy) return;
  setBusy(true);
  alert.textContent = '';
  notice.textContent = '';
  if (form) clearErrors(form, alert);
  let failure;
  try {
    await action();
  } catch (error) {
    failure = error;
  } finally {
    setBusy(false);
  }
  // restore panel interactivity before moving focus into it
  if (failure) showError(failure, alert, form);
  return !failure;
}

filter.addEventListener('submit', (event) => {
  event.preventDefault();
  run(async () => {
    filters = new URLSearchParams({ status: filter.elements.status.value, limit: filter.elements.limit.value });
    const query = filter.elements.query.value.trim();
    if (query) filters.set('query', query);
    card.hidden = true;
    await queue();
  });
});
next.addEventListener('click', () => run(async () => { card.hidden = true; await queue(nextCursor); }));
document.querySelector('[data-first]').addEventListener('click', () => run(async () => { card.hidden = true; await queue(); }));

await run(async () => {
  actor = await accountState();
  if (!actor || !['moderator', 'administrator'].includes(actor.user.role)) throw new Error('moderator or administrator access required');
  panel.hidden = false;
  await queue();
});
