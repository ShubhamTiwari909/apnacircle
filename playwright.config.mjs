import { defineConfig, devices } from '@playwright/test';

export default defineConfig({
  testDir: './e2e',
  workers: 1,
  reporter: 'list',
  use: {
    ...devices['Desktop Chrome'],
    baseURL: 'http://127.0.0.1:4173',
    serviceWorkers: 'block',
    trace: 'retain-on-failure',
  },
  webServer: {
    command: 'pnpm --filter @apnacircle/web exec astro build && node e2e/serve.mjs',
    env: {
      APNACIRCLE_ADAPTER: 'vercel',
      ASTRO_TELEMETRY_DISABLED: '1',
      VERCEL_ENV: 'production',
      PUBLIC_SITE_URL: 'http://127.0.0.1:4173',
    },
    url: 'http://127.0.0.1:4173/__test/observations',
    timeout: 120_000,
    reuseExistingServer: false,
  },
});
