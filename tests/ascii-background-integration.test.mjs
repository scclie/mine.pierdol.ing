import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import vm from 'node:vm';

const read = (path) => readFile(new URL(`../${path}`, import.meta.url), 'utf8');
const rule = (css, selector) => {
  const escaped = selector.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const match = css.match(new RegExp(`${escaped}\\s*\\{([^}]+)\\}`));
  assert.ok(match, `Missing ${selector} rule`);
  return match[1];
};

test('template places a decorative text-only asset layer before the shell and loads the module after header', async () => {
  const base = await read('layouts/base.shtml');
  assert.match(base, /<div class="ascii-background" aria-hidden="true" data-ascii-frames-src="\$site\.asset\('ascii\/glyph-glitch-text-frames\.json'\)\.link\(\)">\s*<pre data-ascii-frame><\/pre>\s*<\/div>\s*<div class="shell">/);
  assert.match(base, /js\/header\.js[\s\S]*<script type="module" src="\$site\.asset\('js\/ascii-background\.js'\)\.link\(\)"><\/script>/);
});

test('renderer uses validated fixed text frames, uniform scaling, reduced motion and isolated failure', async () => {
  const js = await read('assets/js/ascii-background.js');
  assert.doesNotMatch(js, /Math\.random|\b(?:canvas|svg|video|Image|createElement|createElementNS|innerHTML|outerHTML|insertAdjacentHTML|document\.write)\b/);
  assert.equal((js.match(/\bfetch\(/g) || []).length, 1);
  for (const pattern of [/typeof frame !== 'string'/, /lines\.length !== rows/, /line\.length !== cols/, /frames\.length !== frameCount/, /Number\.isFinite\(fps\)/, /prefers-reduced-motion: reduce/, /textContent = frames\[0\]/, /textContent = ''/, /console\.error\(/, /1000 \/ fps/, /offsetWidth/, /offsetHeight/, /Math\.max\(/, /setProperty\('--ascii-scale'/]) {
    assert.match(js, pattern);
  }
  assert.doesNotMatch(js, /\.(?:innerText|nodeValue|width|height|fontSize|lineHeight)\s*=/);
});

test('CSS keeps the immutable grid behind readable content without interaction or viewport-driven text sizing', async () => {
  const css = await read('assets/css/layout.css');
  const layer = rule(css, '.ascii-background');
  const pre = rule(css, '.ascii-background pre');
  const shell = rule(css, '.shell');
  const skip = rule(css, '.skip-link');
  for (const pattern of [/position:\s*fixed/, /inset:\s*0/, /pointer-events:\s*none/, /user-select:\s*none/, /overflow:\s*hidden/, /opacity:\s*0\.\d+/, /color:\s*var\(--nord4\)/]) assert.match(layer, pattern);
  assert.match(pre, /white-space:\s*pre\s*;/);
  assert.match(pre, /font:\s*10px\/12px monospace\s*;/);
  assert.match(pre, /letter-spacing:\s*calc\(10px - 1ch\)\s*;/);
  assert.match(pre, /transform:\s*scale\(var\(--ascii-scale,\s*1\)\)/);
  assert.doesNotMatch(pre, /\b(?:vw|vh|vmin|vmax|clamp)\b|pre-wrap|break-all/);
  assert.match(shell, /position:\s*relative/);
  assert.match(shell, /background:\s*rgb\(59 66 82 \/ 0\.\d+\)/);
  const z = (body) => Number(body.match(/z-index:\s*(-?\d+)/)?.[1]);
  assert.ok(z(shell) > z(layer));
  assert.ok(z(skip) > z(shell));
});

test('Zine publishes each new asset once and staging copies ascii without changing protected page copies', async () => {
  const config = await read('zine.ziggy');
  for (const asset of ['js/ascii-background.js', 'ascii/glyph-glitch-text-frames.json']) {
    assert.equal(config.split(`"${asset}"`).length - 1, 1);
  }
  const build = await read('scripts/build.mjs');
  assert.match(build, /for \(const directory of \['css', 'js', 'ascii'\]\)/);
  assert.match(build, /await cp\(join\(root, 'assets', directory\), join\(stage, 'assets', directory\), \{ recursive: true \}\)/);
  assert.match(build, /for \(const page of \['index', 'rules', 'login'\]\)/);
  assert.match(build, /await cp\(join\(root, `content\/\$\{page\}\.md`\), join\(stage, `content\/\$\{page\}\.smd`\)\)/);
});

async function render(data, { reduced = false, failure = false } = {}) {
  const writes = [];
  const scales = [];
  const errors = [];
  const listeners = {};
  const timers = new Map();
  const pre = {
    offsetWidth: 1600,
    offsetHeight: 1008,
    style: { setProperty: (...args) => scales.push(args) },
    set textContent(value) { writes.push(value); },
  };
  const layer = {
    dataset: { asciiFramesSrc: '/assets/ascii/glyph-glitch-text-frames.json' },
    clientWidth: 800,
    clientHeight: 600,
    querySelector: (selector) => { assert.equal(selector, '[data-ascii-frame]'); return pre; },
  };
  const motion = {
    matches: reduced,
    addEventListener: (event, callback) => { assert.equal(event, 'change'); listeners.motion = callback; },
  };
  let fetches = 0;
  const context = vm.createContext({
    document: { querySelector: (selector) => { assert.equal(selector, '[data-ascii-frames-src]'); return layer; } },
    window: {
      matchMedia: (query) => { assert.equal(query, '(prefers-reduced-motion: reduce)'); return motion; },
      addEventListener: (event, callback) => { assert.equal(event, 'resize'); listeners.resize = callback; },
    },
    fetch: async (url) => {
      fetches++;
      assert.equal(url, layer.dataset.asciiFramesSrc);
      if (failure) throw new Error('unavailable');
      return { ok: true, json: async () => data };
    },
    console: { error: (...args) => errors.push(args) },
    setInterval: (callback, delay) => { timers.set(1, { callback, delay }); return 1; },
    clearInterval: (id) => timers.delete(id),
  });
  await vm.runInContext(await read('assets/js/ascii-background.js'), context);
  return { writes, scales, errors, timers, listeners, layer, motion, fetches };
}

const valid = { cols: 3, rows: 2, fps: 12, frameCount: 2, frames: ['@  \n ##', ' $ \nM  '] };

test('renderer starts at frame zero, plays the exact sequence at JSON fps and resizes only the scale', async () => {
  const result = await render(valid);
  assert.deepEqual(result.writes, [valid.frames[0]]);
  assert.equal(result.fetches, 1);
  assert.equal(result.timers.get(1).delay, 1000 / 12);
  result.timers.get(1).callback();
  result.timers.get(1).callback();
  assert.deepEqual(result.writes, [valid.frames[0], valid.frames[1], valid.frames[0]]);
  assert.deepEqual(result.scales, [['--ascii-scale', String(25 / 42)]]);
  result.layer.clientWidth = 400;
  result.layer.clientHeight = 252;
  result.listeners.resize();
  assert.deepEqual(result.scales.at(-1), ['--ascii-scale', '0.25']);
  assert.equal(result.writes.length, 3);
});

test('renderer covers landscape, portrait and square viewports without changing the text grid', async () => {
  const result = await render(valid, { reduced: true });
  for (const { width, height, scale } of [
    { width: 2400, height: 1008, scale: 1.5 },
    { width: 800, height: 2016, scale: 2 },
    { width: 1008, height: 1008, scale: 1 },
  ]) {
    result.layer.clientWidth = width;
    result.layer.clientHeight = height;
    result.listeners.resize();
    const [property, value] = result.scales.at(-1);
    assert.equal(property, '--ascii-scale');
    assert.equal(Number(value), scale);
    assert.ok(1600 * Number(value) >= width);
    assert.ok(1008 * Number(value) >= height);
  }
  assert.deepEqual(result.writes, [valid.frames[0]]);
  assert.equal(result.fetches, 1);
  assert.equal(result.timers.size, 0);
});

test('reduced motion leaves frame zero visible and reacts to preference changes without refetching', async () => {
  const result = await render(valid, { reduced: true });
  assert.deepEqual(result.writes, [valid.frames[0]]);
  assert.equal(result.timers.size, 0);
  result.motion.matches = false;
  result.listeners.motion();
  result.timers.get(1).callback();
  assert.equal(result.writes.at(-1), valid.frames[1]);
  result.motion.matches = true;
  result.listeners.motion();
  assert.equal(result.writes.at(-1), valid.frames[0]);
  assert.equal(result.timers.size, 0);
  assert.equal(result.fetches, 1);
});

test('failed fetch and malformed metadata or any malformed frame leave only an empty layer and one concise error', async () => {
  const cases = [
    [valid, { failure: true }],
    [null],
    [{ ...valid, cols: 0 }],
    [{ ...valid, rows: 1.5 }],
    [{ ...valid, fps: 0 }],
    [{ ...valid, fps: Infinity }],
    [{ ...valid, frameCount: 3 }],
    [{ ...valid, frames: [valid.frames[0], null] }],
    [{ ...valid, frames: [valid.frames[0], '@  '] }],
    [{ ...valid, frames: [valid.frames[0], '   \nM '] }],
    [{ ...valid, frames: [valid.frames[0], '\t  \nM  '] }],
  ];
  for (const [data, options] of cases) {
    const result = await render(data, options);
    assert.deepEqual(result.writes, ['']);
    assert.equal(result.errors.length, 1);
    assert.equal(result.timers.size, 0);
    assert.equal(result.scales.length, 0);
  }
});
