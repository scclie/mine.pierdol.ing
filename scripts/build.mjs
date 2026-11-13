import { spawnSync } from 'node:child_process';
import { cp, mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { buildCommitFrom, injectBuildCommit } from './build-commit.mjs';

const root = fileURLToPath(new URL('../', import.meta.url));
process.umask(0o077);
const zine = process.env.ZINE_BIN || 'zine';
const version = spawnSync(zine, ['version'], { encoding: 'utf8' });
if (version.status !== 0 || `${version.stdout || ''}${version.stderr || ''}`.trim() !== '0.13.0') {
  console.error('Zine 0.13.0 is required. Run this command in the repository Nix development shell.');
  process.exit(1);
}

// keep source paths unchanged and adapt only during build
await mkdir('/tmp/opencode/task12-fix-2', { recursive: true, mode: 0o700 });
const stage = await mkdtemp('/tmp/opencode/task12-fix-2/build-');
try {
  await mkdir(join(stage, 'content'), { recursive: true });
  await mkdir(join(stage, 'layouts/templates'), { recursive: true });
  await cp(join(root, 'zine.ziggy'), join(stage, 'zine.ziggy'));
  for (const page of ['index', 'rules', 'login']) {
    await cp(join(root, `content/${page}.md`), join(stage, `content/${page}.smd`));
    await cp(join(root, `layouts/${page}.shtml`), join(stage, `layouts/${page}.shtml`));
  }
  // pages contain no editable markdown; generate metadata in staging only
  for (const [page, section] of [['account', 'account'], ['admin-applications', 'admin/applications']]) {
    await mkdir(join(stage, 'content', section), { recursive: true });
    await writeFile(join(stage, 'content', section, 'index.smd'), `---\n.title = "${page}",\n.description = "${page}",\n.date = .date("2026-11-11T00:00:00"),\n.layout = "${page}.shtml",\n.custom = .{ .section = "${page}" },\n---\n`);
    await cp(join(root, `layouts/${page}.shtml`), join(stage, `layouts/${page}.shtml`));
  }
  await cp(join(root, 'layouts/base.shtml'), join(stage, 'layouts/templates/base.shtml'));
  const stagedBase = join(stage, 'layouts/templates/base.shtml');
  const template = await readFile(stagedBase, 'utf8');
  await writeFile(stagedBase, injectBuildCommit(template, buildCommitFrom(process.env)));
  for (const directory of ['css', 'js', 'ascii']) {
    await cp(join(root, 'assets', directory), join(stage, 'assets', directory), { recursive: true });
  }
  const result = spawnSync(zine, ['release'], { cwd: stage, stdio: 'inherit', env: { ...process.env, TMPDIR: stage, XDG_CACHE_HOME: join(stage, 'cache') } });
  if (result.status !== 0) throw new Error(`Zine build failed (${result.signal || result.status}).`);
  await cp(join(stage, 'public'), join(root, 'public'), { recursive: true });
} finally {
  await rm(stage, { recursive: true, force: true });
}
