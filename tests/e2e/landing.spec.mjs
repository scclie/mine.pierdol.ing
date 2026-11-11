import { test, expect } from '@playwright/test';
import { mkdir } from 'node:fs/promises';

const endpoint = '**/api/v1/public/servers';

test('login entry is compact and undecorated', async ({ page }, testInfo) => {
  await page.goto('/');
  const entry = page.getByRole('link', { name: '[ login ]', exact: true });
  const rem = testInfo.project.name === 'mobile' ? 14 : 17.28;
  await expect(entry).toHaveCSS('text-decoration-line', 'none');
  expect(await entry.evaluate((element) => parseFloat(getComputedStyle(element).paddingTop))).toBeCloseTo(0.2 * rem, 2);
  expect(await entry.evaluate((element) => parseFloat(getComputedStyle(element).paddingBottom))).toBeCloseTo(0.2 * rem, 2);
});

for (const route of ['/', '/rules', '/login']) {
  test(`gif reference public typography on ${route}`, async ({ page }, testInfo) => {
    await page.goto(route);
    const rem = testInfo.project.name === 'mobile' ? 14 : 17.28;
    for (const [selector, size, weight] of [
      ['h1', 1.25, '700'],
      ['h2, h3', 1, '700'],
      ['.primary-nav a', 1, '700'],
      ['.login-entry', 0.75, '400'],
      ['.login-method', 0.875, '400'],
    ]) {
      for (const element of await page.locator(selector).all()) {
        expect.soft(await element.evaluate((node) => parseFloat(getComputedStyle(node).fontSize))).toBeCloseTo(size * rem, 2);
        await expect.soft(element).toHaveCSS('font-weight', weight);
      }
    }
  });
}

// catch missing labels, unsafe links and layout issues.
for (const [route, sourceName] of [['/', 'index'], ['/rules', 'rules'], ['/login', 'login']]) {
  test(`gif footer matches the source reference on ${route}`, async ({ page }, testInfo) => {
    await page.goto(route);
    const footer = page.locator('.site-footer');
    const meta = footer.locator('.footer-meta');
    const mobile = testInfo.project.name === 'mobile';
    const rem = mobile ? 14 : 17.28;
    await expect(footer).toContainText(`${sourceName}.smd`);
    await expect(footer.getByText('01234567', { exact: true })).toBeVisible();
    for (const [name, href] of [
      ['source', 'https://git.sccl.cc/scclie/mine.pierdol.ing'],
      ['built with zig zine', 'https://zine-ssg.io'],
      ['sccl.cc', 'https://sccl.cc'],
    ]) {
      const link = footer.getByRole('link', { name, exact: true });
      await expect(link).toHaveAttribute('href', href);
      await expect(link).toHaveAttribute('target', '_blank');
      await expect(link).toHaveAttribute('rel', /\bnoreferrer\b/);
    }
    await expect(footer.getByRole('link')).toHaveCount(3);
    await expect(footer).toHaveCSS('display', 'flex');
    await expect(footer).toHaveCSS('align-items', 'center');
    await expect(footer).toHaveCSS('justify-content', 'space-between');
    await expect(footer).toHaveCSS('color', 'rgb(216, 222, 233)');
    await expect(footer).toHaveCSS('font-size', `${mobile ? 12.25 : 17.28}px`);
    await expect(meta).toHaveCSS('display', 'flex');
    await expect(meta).toHaveCSS('flex-wrap', 'wrap');
    await expect(meta).toHaveCSS('align-items', 'center');
    expect(await meta.evaluate((element) => parseFloat(getComputedStyle(element).gap))).toBeCloseTo(rem, 2);
    for (const credit of await footer.locator('.zine-credit').all()) {
      await expect(credit).toHaveCSS('color', 'rgb(76, 86, 106)');
      await expect(credit).toHaveCSS('text-decoration-line', 'none');
      expect(await credit.evaluate((element) => parseFloat(getComputedStyle(element).fontSize))).toBeCloseTo((await credit.getAttribute('class')).includes('footer-commit') ? 0.65 * rem : 0.75 * rem, 2);
    }
    await expect(footer.locator('.footer-commit')).toHaveCSS('opacity', '0.7');
    await expect(footer.locator('.symbol')).toHaveCSS('color', 'rgb(136, 192, 208)');
    await expect(footer.locator('.symbol')).toHaveCSS('text-decoration-line', 'none');
    await expect(footer).toHaveCSS('flex-direction', mobile ? 'column' : 'row');
    if (mobile) {
      await expect(footer).toHaveCSS('gap', '7px');
      await expect(footer).toHaveCSS('text-align', 'center');
    }
    await mkdir('/tmp/opencode/footer-reference/screenshots', { recursive: true });
    await page.screenshot({ path: `/tmp/opencode/footer-reference/screenshots/${sourceName}-${testInfo.project.name}.png`, fullPage: true });
    await page.setViewportSize({ width: 320, height: 844 });
    await expect(footer).toHaveCSS('flex-direction', 'column');
    await expect(footer).toHaveCSS('gap', '7px');
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
  });
}

const planned = async (page) => {
  await expect(page.locator('[data-server-status]')).toHaveText(['planned', 'planned']);
  await expect(page.locator('[data-server-online]')).toHaveText(['off / not launched', 'off / not launched']);
};

// catch changes in reference tokens and labels.
for (const route of ['/', '/login']) {
  test(`reference alignment shell and accessible controls on ${route}`, async ({ page }, testInfo) => {
    await page.goto(route);
    const mobile = testInfo.project.name === 'mobile';
    const rem = mobile ? 14 : 17.28;
    const nord8 = 'rgb(136, 192, 208)';
    const shell = page.locator('.shell');
    const header = page.locator('.site-header');
    const footer = page.locator('.site-footer');
    await expect.soft(page.locator('html')).toHaveCSS('font-size', mobile ? '14px' : '17.28px');
    await expect.soft(page.locator('html')).toHaveCSS('line-height', mobile ? '22.4px' : '27.648px');
    await expect.soft(page.locator('html')).toHaveCSS('-webkit-font-smoothing', 'none');
    await expect.soft(shell).toHaveCSS('border-top-width', '2px');
    await expect.soft(shell).toHaveCSS('border-top-color', nord8);
    await expect.soft(header).toHaveCSS('border-bottom-color', nord8);
    await expect.soft(header).toHaveCSS('border-bottom-width', '1px');
    await expect.soft(footer).toHaveCSS('border-top-color', nord8);
    await expect.soft(footer).toHaveCSS('border-top-width', '1px');
    for (const [locator, property, expected] of [
      [shell, 'width', mobile ? 370.5 : 1036.8],
      [shell, 'padding-top', (mobile ? 0.625 : 1.25) * rem],
      [header, 'margin-bottom', 0.9375 * rem],
      [header, 'padding-bottom', 0.625 * rem],
      [footer, 'margin-top', 1.25 * rem],
      [footer, 'padding-top', 0.625 * rem],
    ]) {
      expect.soft(await locator.evaluate((element, property) => parseFloat(getComputedStyle(element).getPropertyValue(property)), property)).toBeCloseTo(expected, 1);
    }
    await expect.soft(page.getByRole('navigation').getByRole('link')).toHaveText(['home', 'rules']);
    await expect.soft(header.getByRole('link')).toHaveText(['home', 'rules', '[ login ]']);
    for (const name of ['home', 'rules']) {
      const link = page.getByRole('link', { name, exact: true });
      await expect.soft(link).toHaveAccessibleName(name);
      await expect.soft(link).toHaveCSS('font-weight', '700');
      await expect.soft(link).toHaveCSS('color', route === '/' && name === 'home' ? nord8 : 'rgb(216, 222, 233)');
    }
    const entry = page.getByRole('link', { name: '[ login ]', exact: true });
    await expect.soft(entry).toHaveAttribute('href', '/login');
    if (mobile) {
      await expect.soft(header).toHaveCSS('flex-direction', 'column');
      await expect.soft(header).toHaveCSS('gap', '7px');
      const headerBox = await header.boundingBox();
      for (const control of [page.getByRole('navigation'), page.locator('.login-entry')]) {
        const box = await control.boundingBox();
        expect.soft(box.x + box.width / 2).toBeCloseTo(headerBox.x + headerBox.width / 2, 0);
      }
    }
    if (route === '/login') {
      const methods = page.locator('[data-login-methods]');
      await expect.soft(methods.getByRole('link')).toHaveCount(1);
      const discord = methods.getByRole('link', { name: '[ continue with discord ]', exact: true });
      await expect.soft(discord).toHaveAttribute('href', '/api/v1/auth/discord');
      await expect.soft(page.getByRole('heading', { level: 1 })).toHaveText('login');
    }

    // check structure to catch css changes.
    for (const control of [page.locator('.login-entry'), ...(route === '/login' ? [page.locator('.login-method')] : [])]) {
      await expect.soft(control).toHaveCSS('font-weight', '400');
      await expect.soft(control).toHaveCSS('color', nord8);
      await expect.soft(control).toHaveCSS('background-color', 'rgba(0, 0, 0, 0)');
      await expect.soft(control).toHaveCSS('border-top-color', nord8);
      await expect.soft(control).toHaveCSS('border-radius', '0px');
      await control.hover();
      await expect.soft(control).toHaveCSS('background-color', nord8);
      await expect.soft(control).toHaveCSS('color', 'rgb(0, 0, 0)');
      await page.mouse.move(0, 0);
      await page.keyboard.press('Tab');
      for (let tabs = 0; tabs < 6 && !(await control.evaluate((element) => element === document.activeElement)); tabs++) {
        await page.keyboard.press('Tab');
      }
      await expect.soft(control).toBeFocused();
      await expect.soft(control).toHaveCSS('background-color', nord8);
      await expect.soft(control).toHaveCSS('color', 'rgb(0, 0, 0)');
      await page.locator('main').focus();
    }
    await page.locator('main').blur();
    await mkdir('/tmp/opencode/reference-alignment/screenshots', { recursive: true });
    await page.screenshot({ path: `/tmp/opencode/reference-alignment/screenshots/${route === '/' ? 'landing' : 'login'}-${testInfo.project.name}.png`, fullPage: true });
    await page.setViewportSize({ width: 320, height: 844 });
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
  });
}

// catch missing content, style and accessibility issues
test('landing exposes the planned servers and public navigation without a session', async ({ page, context }) => {
  await context.clearCookies();
  await page.goto('/');
  await expect(page.getByRole('heading', { level: 1 })).toHaveCount(1);
  const servers = page.getByRole('list', { name: 'Servers' });
  await expect(servers).toBeVisible();
  const cards = servers.getByRole('listitem');
  await expect(cards).toHaveCount(2);
  for (const card of await cards.all()) {
    await expect(card.getByRole('heading')).toBeVisible();
    await expect(card.getByRole('heading')).toContainText(/\S/);
    await expect(card.locator('[data-server-status]')).toHaveText('planned');
    await expect(card.locator('[data-server-online]')).toContainText('off / not launched');
    await expect(card).toHaveCSS('border-radius', '0px');
    await expect(card).toHaveCSS('border-top-width', '1px');
    await expect(card).toHaveCSS('box-shadow', 'none');
    await expect(card).toHaveCSS('background-image', 'none');
  }
  await expect(page.getByRole('link', { name: 'rules', exact: true })).toHaveAttribute('href', '/rules');
  await expect(page.getByRole('link', { name: 'home', exact: true })).toHaveAttribute('aria-current', 'page');
  await expect(page.getByRole('link', { name: '[ login ]', exact: true })).toHaveAttribute('href', '/login');
});

// catch missing login, layout changes and extra providers.
test('login entry opens the static Discord-only page', async ({ page }, testInfo) => {
  await page.goto('/');
  const entry = page.getByRole('link', { name: '[ login ]', exact: true });
  await expect(entry).toHaveAttribute('href', '/login');
  const checkHeader = async () => {
    await expect(entry).toBeVisible();
    await expect(entry).toHaveCSS('border-top-width', '1px');
    await expect(entry).toHaveCSS('border-top-style', 'solid');
    await expect(entry).toHaveCSS('border-top-color', 'rgb(136, 192, 208)');
    await expect(entry).toHaveCSS('border-radius', '0px');
    await expect(page.getByRole('navigation').getByRole('link')).toHaveText(['home', 'rules']);
    await expect(page.getByRole('navigation').getByRole('link', { name: '[ login ]', exact: true })).toHaveCount(0);
    const header = await page.locator('.site-header').boundingBox();
    const control = await entry.boundingBox();
    if (testInfo.project.name === 'mobile') {
      expect(Math.abs(header.x + header.width / 2 - control.x - control.width / 2)).toBeLessThan(1);
    } else {
      expect(Math.abs(header.x + header.width - control.x - control.width)).toBeLessThan(1);
    }
  };
  await checkHeader();
  await mkdir('/tmp/opencode/login-entry/screenshots', { recursive: true });
  await page.screenshot({ path: `/tmp/opencode/login-entry/screenshots/landing-${testInfo.project.name}.png`, fullPage: true });
  await entry.click();
  await expect(page).toHaveURL(/\/login\/?$/);
  await expect(page.getByRole('heading', { level: 1, name: 'login', exact: true })).toBeVisible();
  await checkHeader();
  const methods = page.locator('[data-login-methods]');
  const discord = methods.getByRole('link', { name: '[ continue with discord ]', exact: true });
  await expect(discord).toBeVisible();
  await expect(discord).toHaveAttribute('href', '/api/v1/auth/discord');
  await expect(methods.getByRole('link')).toHaveCount(1);
  await expect(page.getByRole('main').getByRole('link')).toHaveCount(1);
  await expect(page.locator('input, button, form')).toHaveCount(0);
  await expect(discord).toHaveCSS('border-radius', '0px');
  await page.screenshot({ path: `/tmp/opencode/login-entry/screenshots/login-${testInfo.project.name}.png`, fullPage: true });
  for (const name of ['Skip to content', 'home', 'rules', '[ login ]']) {
    await page.keyboard.press('Tab');
    await expect(page.getByRole('link', { name, exact: true })).toBeFocused();
  }
  await expect(entry).toHaveCSS('outline-style', 'solid');
  await expect(entry).toHaveCSS('outline-width', '2px');
  await page.keyboard.press('Tab');
  await expect(discord).toBeFocused();
  await expect(discord).toHaveCSS('outline-style', 'solid');
  await expect(discord).toHaveCSS('outline-width', '2px');
  await page.screenshot({ path: `/tmp/opencode/login-entry/screenshots/login-focus-${testInfo.project.name}.png`, fullPage: true });
  await page.setViewportSize({ width: 320, height: 844 });
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true);
});

test('valid same-origin server data updates only the matching status and online text', async ({ page }) => {
  const fetches = [];
  page.on('request', (request) => {
    if (request.resourceType() === 'fetch') fetches.push(request.url());
  });
  await page.route(endpoint, (route) => route.fulfill({ json: { servers: [
    { id: 'vanilla', status: 'offline', online: 0 },
    { id: 'oldshit-mods', status: 'online', online: 3 },
  ] } }));
  await page.goto('/');
  const forge = page.locator('[data-server-id="oldshit-mods"]');
  const vanilla = page.locator('[data-server-id="vanilla"]');
  await expect(forge.locator('[data-server-status]')).toHaveText('online');
  await expect(forge.locator('[data-server-online]')).toHaveText('3 players online');
  await expect(vanilla.locator('[data-server-status]')).toHaveText('offline');
  await expect(vanilla.locator('[data-server-online]')).toHaveText('0 players online');
  await expect(forge.getByRole('heading')).toContainText(/\S/);
    expect(fetches).toEqual([new URL('/api/v1/public/servers', page.url()).href]);
});

test('partial valid data keeps undeclared counts and unmatched cards honest', async ({ page }) => {
  await page.route(endpoint, (route) => route.fulfill({ json: { servers: [
    { id: 'oldshit-mods', status: 'planned', online: null },
    { id: 'future-server', status: 'offline', online: 0 },
  ] } }));
  await page.goto('/');
  await page.waitForLoadState('networkidle');
  await expect(page.locator('[data-server-status]')).toHaveText(['planned', 'planned']);
  // The matched card is hydrated; the unmatched card keeps its literal static copy.
  await expect(page.locator('[data-server-online]')).toHaveText(['offline · not launched', 'off / not launched']);
  await expect(page.getByRole('list', { name: 'Servers' }).getByRole('listitem')).toHaveCount(2);
});

const failures = [
  ['unavailable API', (route) => route.fulfill({ status: 503, json: { error: { code: 'unavailable' } } })],
  ['network failure', (route) => route.abort('failed')],
  ['invalid JSON', (route) => route.fulfill({ contentType: 'application/json', body: '{' })],
  ['HTML instead of JSON', (route) => route.fulfill({ contentType: 'text/html', body: '<h1>Sign in</h1>' })],
  ['missing servers', (route) => route.fulfill({ json: {} })],
  ['invalid status', (route) => route.fulfill({ json: { servers: [{ id: 'oldshit-mods', status: '<img src=x>', online: 1 }] } })],
  ['invalid count', (route) => route.fulfill({ json: { servers: [{ id: 'oldshit-mods', status: 'online', online: -1 }] } })],
  ['string count', (route) => route.fulfill({ json: { servers: [{ id: 'oldshit-mods', status: 'online', online: '5' }] } })],
  ['duplicate identity', (route) => route.fulfill({ json: { servers: [
    { id: 'oldshit-mods', status: 'online', online: 2 },
    { id: 'oldshit-mods', status: 'offline', online: 0 },
  ] } })],
  ['partially malformed payload', (route) => route.fulfill({ json: { servers: [
    { id: 'oldshit-mods', status: 'online', online: 2 }, null,
  ] } })],
];

for (const [name, respond] of failures) {
  test(`${name} preserves the static planned/offline fallback`, async ({ page }) => {
    const errors = [];
    page.on('pageerror', (error) => errors.push(error.message));
    await page.route(endpoint, respond);
    await page.goto('/');
    await page.waitForLoadState('networkidle');
    await planned(page);
    expect(errors).toEqual([]);
  });
}

test('API redirects cannot send browser fetches outside the API prefix', async ({ page }) => {
  const escaped = [];
  page.on('request', (request) => {
    if (request.url().includes('/outside-api')) escaped.push(request.url());
  });
  await page.route(endpoint, (route) => route.fulfill({ status: 302, headers: { location: '/outside-api' } }));
  await page.goto('/');
  await page.waitForLoadState('networkidle');
  await planned(page);
  expect(escaped).toEqual([]);
});

test('public pages are keyboard navigable, readable, and visually reviewable', async ({ page }, testInfo) => {
  await page.goto('/');
  await page.waitForLoadState('networkidle');
  await mkdir('/tmp/opencode/task9/screenshots', { recursive: true });
  await page.screenshot({ path: `/tmp/opencode/task9/screenshots/landing-${testInfo.project.name}.png`, fullPage: true });
  await page.keyboard.press('Tab');
  const skip = page.getByRole('link', { name: 'Skip to content' });
  await expect(skip).toBeFocused();
  await expect(skip).toBeVisible();
  await expect(skip).toHaveCSS('outline-style', 'solid');
  await page.keyboard.press('Enter');
  await expect(page.getByRole('main')).toBeFocused();
  await page.goto('/');
  await page.keyboard.press('Tab');
  await page.keyboard.press('Tab');
  await page.keyboard.press('Tab');
  await expect(page.getByRole('link', { name: 'rules', exact: true })).toBeFocused();
  await page.keyboard.press('Enter');
  await expect(page).toHaveURL(/\/rules\/?$/);
  await expect(page.locator('main > h1')).toHaveText('rules');
  await expect(page.getByRole('link', { name: 'rules', exact: true })).toHaveAttribute('aria-current', 'page');
  await expect(page.getByRole('main')).toBeVisible();
  await expect(page.getByRole('main').getByRole('article')).toBeVisible();
  await expect(page.getByRole('main').getByRole('article')).toContainText(/\S/);
  await page.screenshot({ path: `/tmp/opencode/task9/screenshots/rules-${testInfo.project.name}.png`, fullPage: true });
  for (const route of ['/', '/rules', '/login']) {
    await page.goto(route);
    await page.setViewportSize({ width: 320, height: 844 });
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true);
  }
});

test.describe('without JavaScript', () => {
  test.use({ javaScriptEnabled: false });
  test('both planned cards and the editor-owned rules are in generated HTML', async ({ page }) => {
    await page.goto('/');
    await planned(page);
    await page.getByRole('link', { name: 'rules', exact: true }).click();
    await expect(page.getByRole('heading', { level: 1, name: 'rules', exact: true })).toBeVisible();
    await expect(page.getByRole('link', { name: 'rules', exact: true })).toHaveAttribute('aria-current', 'page');
    await expect(page.getByRole('main').getByRole('article')).toBeVisible();
    await expect(page.getByRole('main').getByRole('article')).toContainText(/\S/);
    await page.getByRole('link', { name: '[ login ]', exact: true }).click();
    await expect(page.getByRole('heading', { level: 1, name: 'login', exact: true })).toBeVisible();
    await expect(page.locator('[data-login-methods]').getByRole('link')).toHaveAttribute('href', '/api/v1/auth/discord');
  });
});
