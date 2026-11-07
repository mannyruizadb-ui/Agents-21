import { defineConfig } from 'playwright/test';

// Local-only config: no webServer. Start local Supabase, the Edge Functions (host Deno), the proxy and vite
// on :5179 first (see the QA report). Never point this at the cloud.
export default defineConfig({
  testDir: '.',
  timeout: 90_000,
  workers: 1,
  fullyParallel: false,
  reporter: [['list']],
  use: {
    baseURL: 'http://localhost:5179',
    viewport: { width: 390, height: 844 },
    deviceScaleFactor: 1,
    launchOptions: {
      executablePath:
        process.env.CHROME_PATH ?? '/opt/pw-browsers/chromium-1243/chrome-linux64/chrome',
    },
  },
});
