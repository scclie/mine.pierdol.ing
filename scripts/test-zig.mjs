import { localRun, zigArgs } from './test-local.mjs';
await localRun('zig', async ({ directory, command }) => {
  await command('zig', ['build', 'test', ...zigArgs(directory), ...process.argv.slice(2)]);
});
