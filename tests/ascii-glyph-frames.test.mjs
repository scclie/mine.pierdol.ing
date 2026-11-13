import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

const assetURL = new URL('../assets/ascii/glyph-glitch-text-frames.json', import.meta.url);
const generatorURL = new URL('../scripts/generate-ascii-glyph-frames.mjs', import.meta.url);
const presetPath = '/home/paper/Downloads/glyph-preset-1794589821313.json';

test('production frames preserve the new preset glyph mapping and fixed text grid', async () => {
  const output = JSON.parse(await readFile(assetURL, 'utf8'));
  const preset = JSON.parse(await readFile(presetPath, 'utf8'));
  assert.equal(output.source.archive, '/home/paper/Downloads/AsciiArt(1).zip');
  assert.equal(output.preset.path, presetPath);
  assert.deepEqual(output.preset.layer, preset.layer);
  assert.equal(output.preset.backgroundColor, preset.backgroundColor);
  assert.equal(output.cols, 160);
  assert.equal(output.rows, 84);
  assert.equal(output.fps, 12);
  assert.equal(output.frameCount, 48);
  assert.equal(output.frames.length, 48);
  assert.equal(output.charset, ' .:-=+*#%@');
  assert.equal(output.preset.layer.characterSet, 'standard');
  assert.ok(!('glyphVariation' in output));
  const allowed = new Set(`${output.charset} `);
  const used = new Set();
  for (const [index, frame] of output.frames.entries()) {
    assert.equal(typeof frame, 'string');
    assert.equal(frame.length, 84 * 160 + 83);
    const rows = frame.split('\n');
    assert.equal(rows.length, 84);
    for (const row of rows) {
      assert.equal(row.length, 160, `full row width in frame ${index}`);
      for (const glyph of row) {
        assert.ok(allowed.has(glyph), `unexpected glyph ${JSON.stringify(glyph)}`);
        used.add(glyph);
      }
    }
  }
  assert.ok([...used].some((glyph) => glyph !== ' '));
  assert.ok(new Set(output.frames).size > 1, 'the preset noise animates');
  assert.deepEqual(output.timestampsSeconds, Array.from({ length: 48 }, (_, i) => i / 12));
});

test('generator reads only the new inputs and applies no artificial glyph replacement', async () => {
  const source = await readFile(generatorURL, 'utf8');
  assert.ok(source.includes('AsciiArt(1).zip'));
  assert.ok(source.includes('glyph-preset-1794589821313.json'));
  assert.doesNotMatch(source, /AsciiArt\.zip|glyph-preset-1794588011480|glyphVariation|@#%&8\$WM|Math\.random\s*\(/);
  assert.doesNotMatch(source, /brainstorm\/.*\/content\//);
});

test('two independent generator runs are byte-identical to the checked-in asset', async () => {
  const { generateAsset } = await import(generatorURL.href);
  const original = await readFile(assetURL, 'utf8');
  const first = `${JSON.stringify(await generateAsset())}\n`;
  const second = `${JSON.stringify(await generateAsset())}\n`;
  assert.equal(first, original);
  assert.equal(second, first);
  const output = JSON.parse(first);
  assert.equal(output.reconstruction.randomness, 'none; archived fixed-permutation simplex3');
});
