import { defineConfig } from '@playwright/test';

export default defineConfig({
  testDir: './tests/e2e',
  workers: 2,
  outputDir: '/tmp/opencode/task9/test-results',
  reporter: 'list',
  use: {
    baseURL: 'http://127.0.0.1:3099',
    launchOptions: process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH
      ? { executablePath: process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH }
      : {},
    trace: 'retain-on-failure',
  },
  projects: [
    { name: 'desktop', use: { viewport: { width: 1440, height: 1000 } } },
    { name: 'mobile', use: { viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true } },
  ],
  webServer: {
    command: 'node tests/support/static-server.mjs',
    env: { TASK10_OAUTH_STUB: '1' },
    url: 'http://127.0.0.1:3099/__ready',
    reuseExistingServer: false,
  },
});
