function validateFrames(data) {
  if (!data || typeof data !== 'object') throw new Error('Invalid frame data');
  const { cols, rows, fps, frameCount, frames } = data;
  if (!Number.isSafeInteger(cols) || cols <= 0 ||
      !Number.isSafeInteger(rows) || rows <= 0 ||
      !Number.isSafeInteger(frameCount) || frameCount <= 0 ||
      !Number.isFinite(fps) || fps <= 0 ||
      !Array.isArray(frames) || frames.length !== frameCount) {
    throw new Error('Invalid frame metadata');
  }
  for (const frame of frames) {
    if (typeof frame !== 'string') throw new Error('Invalid text frame');
    const lines = frame.split('\n');
    if (lines.length !== rows || lines.some((line) => line.length !== cols || !/^[\x20-\x7e]*$/.test(line))) {
      throw new Error('Invalid frame dimensions or characters');
    }
  }
  return { frames, fps };
}

async function initializeBackground(layer, pre) {
  let timer;
  try {
    const response = await fetch(layer.dataset.asciiFramesSrc);
    if (!response.ok) throw new Error('Frame request failed');
    const { frames, fps } = validateFrames(await response.json());
    const motion = window.matchMedia('(prefers-reduced-motion: reduce)');
    let frameIndex = 0;
    pre.textContent = frames[0];

    const fit = () => {
      const width = pre.offsetWidth;
      const height = pre.offsetHeight;
      if (width > 0 && height > 0) {
        const scale = Math.max(layer.clientWidth / width, layer.clientHeight / height);
        pre.style.setProperty('--ascii-scale', String(scale));
      }
    };
    const updateMotion = () => {
      clearInterval(timer);
      timer = undefined;
      if (motion.matches) {
        frameIndex = 0;
        pre.textContent = frames[0];
      } else {
        timer = setInterval(() => {
          frameIndex = (frameIndex + 1) % frames.length;
          pre.textContent = frames[frameIndex];
        }, 1000 / fps);
      }
    };

    fit();
    window.addEventListener('resize', fit);
    motion.addEventListener('change', updateMotion);
    if (!motion.matches) updateMotion();
  } catch {
    clearInterval(timer);
    pre.textContent = '';
    console.error('ASCII background: unable to load valid text frames.');
  }
}

const layer = document.querySelector('[data-ascii-frames-src]');
const pre = layer?.querySelector('[data-ascii-frame]');
if (layer && pre) initializeBackground(layer, pre);
