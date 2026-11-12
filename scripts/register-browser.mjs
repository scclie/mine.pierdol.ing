import { registerBrowserGroup } from './test-local.mjs';
import { spawn } from 'node:child_process';

export async function superviseBrowser(executable) {
  const register = registerBrowserGroup();
  // stay in Playwright's detached session; preserve the transport pipes, but
  // retain an anchor until the actual browser exits and membership is recorded.
  const browser = spawn(executable, process.argv.slice(2), { stdio: [0, 1, 2, 3, 4] });
  const snapshot = register;
  for (const signal of ['SIGTERM', 'SIGINT', 'SIGHUP']) process.on(signal, snapshot);
  try {
    const result = await new Promise((resolve, reject) => {
      browser.once('error', reject);
      browser.once('exit', (code, signal) => resolve({ code, signal }));
    });
    register();
    process.exitCode = result.code ?? 1;
  } finally {
    for (const signal of ['SIGTERM', 'SIGINT', 'SIGHUP']) process.off(signal, snapshot);
  }
}
