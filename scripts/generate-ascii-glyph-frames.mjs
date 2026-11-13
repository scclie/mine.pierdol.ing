import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { stripTypeScriptTypes } from 'node:module';
import { pathToFileURL } from 'node:url';
import { createContext, runInContext } from 'node:vm';

const archivePath = '/home/paper/Downloads/AsciiArt(1).zip';
const presetPath = '/home/paper/Downloads/glyph-preset-1794589821313.json';
const assetDirectoryURL = new URL('../assets/ascii/', import.meta.url);
const assetURL = new URL('glyph-glitch-text-frames.json', assetDirectoryURL);
const cols = 160;
const rows = 84;
const fps = 12;
const frameCount = 48;
const sha256 = (bytes) => createHash('sha256').update(bytes).digest('hex');
const archiveMember = (member) => execFileSync('unzip', ['-p', archivePath, member], {
  maxBuffer: 16 * 1024 * 1024,
});

function loadEngine() {
  const context = createContext({});
  const modules = [
    ['brightness', ['pixelBrightness', 'adjustBrightness']],
    ['charsets', ['getCharset', 'getCharForBrightness']],
    ['noise', ['simplex3']],
    ['dither', ['DITHER_FUNCTIONS']],
    ['fx', ['PRE_RENDER_FX']],
  ];
  const hashes = {};
  for (const [name, exports] of modules) {
    const member = `AsciiArt/engine/${name}.ts`;
    const bytes = archiveMember(member);
    hashes[member] = sha256(bytes);
    const javascript = stripTypeScriptTypes(bytes.toString('utf8'))
      .replace(/^import\s+.*$/gm, '')
      .replace(/^export\s+/gm, '');
    runInContext(`(() => {\n${javascript}\nObject.assign(globalThis, { ${exports.join(', ')} });\n})()`, context);
  }
  return { context, hashes };
}

export async function generateAsset() {
  const presetBytes = await readFile(presetPath);
  const preset = JSON.parse(presetBytes);
  const layer = preset.layer;
  if (layer.artStyle !== 'classic' || layer.ditherAlgorithm !== 'bayer' || layer.fxPreset !== 'noise') {
    throw new Error('This generator expects the supplied classic/Bayer/noise preset');
  }
  const source = archiveMember('AsciiArt/source.png');
  if (!source.subarray(0, 8).equals(Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]))) {
    throw new Error('Expected the archived PNG source');
  }

  const rgb = execFileSync('ffmpeg', [
    '-v', 'error', '-threads', '1', '-i', 'pipe:0',
    '-vf', `scale=${cols}:${rows}:flags=bilinear`,
    '-frames:v', '1', '-threads', '1', '-f', 'rawvideo', '-pix_fmt', 'rgb24', 'pipe:1',
  ], { input: source, maxBuffer: 16 * 1024 * 1024 });
  if (rgb.length !== cols * rows * 3) throw new Error('Unexpected sampled RGB size');
  const { context: engine, hashes } = loadEngine();
  const charset = engine.getCharset(layer.characterSet, layer.customCharset);
  const base = new Float32Array(cols * rows);
  for (let i = 0; i < base.length; i++) {
    base[i] = engine.adjustBrightness(
      engine.pixelBrightness(rgb[i * 3], rgb[i * 3 + 1], rgb[i * 3 + 2]),
      layer.brightness, layer.contrast,
    );
  }
  const timestampsSeconds = Array.from({ length: frameCount }, (_, frame) => frame / fps);
  const frames = timestampsSeconds.map((time) => {
    const grid = new Float32Array(base);
    // noise.ts uses a hardcoded permutation: no ambient randomness or PRNG.
    engine.PRE_RENDER_FX[layer.fxPreset](grid, cols, rows, layer, time);
    const dithered = engine.DITHER_FUNCTIONS[layer.ditherAlgorithm](grid, cols, rows, layer.ditherStrength);
    const lines = [];
    for (let y = 0; y < rows; y++) {
      let line = '';
      for (let x = 0; x < cols; x++) {
        const brightness = dithered[y * cols + x];
        line += engine.getCharForBrightness(layer.invertColor ? 1 - brightness : brightness, charset);
      }
      lines.push(line);
    }
    return lines.join('\n');
  });
  return {
    cols, rows, fps, frameCount,
    uniqueFrameCount: new Set(frames).size,
    durationSeconds: frameCount / fps,
    cellWidth: layer.fontSize * layer.characterSpacing,
    cellHeight: layer.fontSize * 1.2,
    alphabet: [...new Set(frames.join('').replaceAll('\n', ''))].sort().join(''),
    charset, timestampsSeconds,
    source: {
      archive: archivePath,
      member: 'AsciiArt/source.png',
      width: source.readUInt32BE(16),
      height: source.readUInt32BE(20),
      sha256: sha256(source),
    },
    preset: { path: presetPath, sha256: sha256(presetBytes), ...preset },
    reconstruction: {
      engine: 'Original archived brightness, simplex3 noise, Bayer dither and classic charset mapping; Float32 writes preserved',
      engineSha256: hashes,
      resampler: 'FFmpeg scale bilinear to RGB24',
      sampledRgbSha256: sha256(rgb),
      randomness: 'none; archived fixed-permutation simplex3',
      mouseDisplacement: false,
      independentlyGenerated: true,
      loop: 'Four-second sample repeated; source defines no seamless loop',
      limitations: [
        'Not pixel-identical to Canvas drawImage resampling',
        'Installed text renderer uses its own font; no mouse displacement',
        'Fixed 160 by 84 grid, not an original recorded viewport',
      ],
    },
    frames,
  };
}

export async function writeAsset() {
  const output = await generateAsset();
  await mkdir(assetDirectoryURL, { recursive: true });
  await writeFile(assetURL, `${JSON.stringify(output)}\n`, 'utf8');
}

if (process.argv[1] && pathToFileURL(process.argv[1]).href === import.meta.url) {
  await writeAsset();
}
