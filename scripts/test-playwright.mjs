import { mkdir, readFile, readdir, writeFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { readPasswords, redact } from './test-secrets.mjs';

export async function runPlaywright({ directory, env, start, afterStop, config, args = [] }) {
  const scratch = `${directory}/secrets/playwright`;
  await mkdir(scratch, { mode: 0o700 });
  // run only after all owned process groups are stopped and verified.
  // prevent raw browser, debug and reporter output from leaking on cancellation.
  afterStop(async () => {
    const passwords = readPasswords(env.TASK12_SECRET_FILE);
    const retain = async (source, target) => {
      await mkdir(target, { recursive: true, mode: 0o700 });
      for (const entry of await readdir(source, { withFileTypes: true })) {
        if (entry.isDirectory()) await retain(`${source}/${entry.name}`, `${target}/${entry.name}`);
        else if (entry.isFile() && /\.(md|json|txt|log)$/.test(entry.name)) {
          await writeFile(`${target}/${entry.name}`, redact(await readFile(`${source}/${entry.name}`, 'utf8'), passwords), { mode: 0o600 });
        }
      }
    };
    await retain(scratch, `${directory}/results`);
    const output = redact(await readFile(`${scratch}/console.log`, 'utf8'), passwords);
    process.stdout.write(output);
  });
  const configPath = `${directory}/playwright.config.mjs`;
  await writeFile(configPath, `export default ${JSON.stringify({ ...config,
    outputDir: `${scratch}/results`, reporter: [[fileURLToPath(new URL('./test-reporter.mjs', import.meta.url)), { outputFile: `${scratch}/report.json` }]],
    use: { ...config.use, trace: 'off', video: 'off', screenshot: 'off' },
  })};\n`, { mode: 0o600 });
  const child = await start(process.execPath, [resolve('node_modules/@playwright/test/cli.js'), 'test', `--config=${configPath}`, ...args], {}, 'secrets/playwright/console.log');
  const result = await child.done;
  if (result.code !== 0) throw new Error(`Playwright failed (${result.code ?? result.signal}); redacted evidence retained after teardown`);
}
