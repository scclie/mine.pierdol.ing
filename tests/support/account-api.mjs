// mock oauth and api behavior for browser tests
// backend authorization is covered by zig route tests
export async function accountApi(page, options = {}) {
  const state = {
    role: 'player', status: null, client: 'licensed', reason: 'Please explain <b>more</b>.',
    nickname: 'Subject_Name', token: 'a'.repeat(64), mutations: [], queries: [], ...options,
  };
  let sequence = 0;
  const rotate = () => { state.token = (++sequence).toString(16).padStart(64, '0'); };
  const account = () => ({
    user: { id: 1, discord_id: '123456789012345678', display_name: 'Test Player', role: state.role },
    application: state.status ? { minecraft_nickname: state.nickname, client_type: state.client, status: state.status, decision_reason: state.status === 'approved' || state.status === 'pending' ? null : state.reason } : null,
    actions: {
      can_submit: state.status === null,
      can_resubmit: state.status === 'rejected_retryable',
      can_change_password: state.status === 'approved' && state.client === 'cracked',
      ...state.actions,
    },
    csrf_token: state.token,
    ...(state.setup ? { password_setup_required: true } : {}),
  });
  const card = () => ({
    user: { id: 2, discord_id: '423456789012345678', discord_username: 'Subject', discord_global_name: 'Subject Player', discord_avatar_hash: null },
    application: { minecraft_nickname: state.nickname, client_type: state.client, status: state.targetStatus || 'pending', about_me: 'I build <b>railways</b>.', discovery_source: 'Friend', decision_reason: state.reason, submitted_at: '2026-01-01 00:00:00+00', decided_at: null, decided_by_user_id: null },
    password_setup_required: false,
  });
  await page.route('**/api/v1/**', async (route) => {
    const request = route.request();
    const url = new URL(request.url());
    const path = url.pathname;
    const json = (body, status = 200) => route.fulfill({ status, json: body });
    const error = (code, status) => json({ error: { code, message: '<img src=x onerror=alert(1)>', request_id: 'test-request' } }, status);
    if (path.startsWith('/api/v1/auth/discord')) return route.fallback();
    if (request.method() === 'GET') {
      if (state.unauthenticated) return error('authentication_required', 401);
      if (path === '/api/v1/account') { rotate(); return json(account()); }
      if (!['moderator', 'administrator'].includes(state.role)) return error('insufficient_role', 403);
      if (path === '/api/v1/admin/applications') {
        state.queries.push(url.search);
        const item = { user_id: 2, discord_id: '423456789012345678', display_name: 'Subject Player', minecraft_nickname: state.nickname, client_type: state.client, status: url.searchParams.get('status') || 'pending', submitted_at: '2026-01-01 00:00:00+00' };
        return json({ applications: state.empty ? [] : [item], next_cursor: state.paginated && !url.searchParams.has('cursor') ? '0'.repeat(31) + '2' : null });
      }
      if (path === '/api/v1/admin/users/2') return json(card());
      return error('not_found', 404);
    }
    const body = request.postDataJSON();
    state.mutations.push({ path, method: request.method(), body, headers: request.headers() });
    if (!request.headers()['content-type']?.includes('application/json')) return error('unsupported_media_type', 415);
    if (request.headers()['x-csrf-token'] !== state.token) return error('csrf_token_invalid', 403);
    if (state.failure) return error(state.failure, state.failureStatus || 422);
    if (path === '/api/v1/auth/logout') return route.fulfill({ status: 204 });
    if (path.includes('/admin/')) {
      rotate();
      if (path.endsWith('/approve')) state.targetStatus = 'approved';
      if (path.endsWith('/reject')) { state.targetStatus = `rejected_${body.kind}`; state.reason = body.reason; }
      if (request.method() === 'PATCH') { state.nickname = body.minecraft_nickname || state.nickname; state.targetStatus = body.status || state.targetStatus; }
      return route.fulfill({ status: 204 });
    }
    if (path.endsWith('/password')) { rotate(); state.setup = false; return route.fulfill({ status: 204 }); }
    state.status = 'pending'; state.client = body.client_type; state.nickname = body.minecraft_nickname;
    rotate();
    return json(account(), request.method() === 'POST' ? 201 : 200);
  });
  return state;
}

export async function signIn(page) {
  await page.goto('/login');
  await page.getByRole('link', { name: '[ continue with discord ]', exact: true }).click();
}

export async function fillApplication(page) {
  await page.getByLabel('minecraft nickname', { exact: true }).fill('Example_Name');
  await page.getByLabel('about me', { exact: true }).fill('I build railways.');
  await page.getByLabel('discovery source', { exact: true }).fill('Friend');
}
