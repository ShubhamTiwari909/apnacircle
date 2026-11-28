import { defineConfig } from 'astro/config';
import cloudflare from '@astrojs/cloudflare';
import vercel from '@astrojs/vercel';
import react from '@astrojs/react';
import tailwindcss from '@tailwindcss/vite';
import { siteOrigin } from './src/lib/seo.ts';

const useVercel = process.env.VERCEL === '1' || process.env.APNACIRCLE_ADAPTER === 'vercel';
const vercelProductionHost = process.env.VERCEL_ENV === 'production' && process.env.VERCEL_PROJECT_PRODUCTION_URL;
const configuredSite = process.env.PUBLIC_SITE_URL || (vercelProductionHost ? `https://${vercelProductionHost}` : undefined);

export default defineConfig({
  site: process.env.VERCEL_ENV === 'preview' ? undefined : siteOrigin(configuredSite),
  adapter: useVercel ? vercel() : cloudflare({
    imageService: 'compile',
    prerenderEnvironment: 'node',
  }),
  integrations: [react()],
  security: {
    csp: {
      directives: [
        "default-src 'self'",
        "img-src 'self' data:",
        "connect-src 'self' https://challenges.cloudflare.com",
        'frame-src https://challenges.cloudflare.com',
      ],
      scriptDirective: { resources: ["'self'", 'https://challenges.cloudflare.com'] },
      styleDirective: { resources: ["'self'", "'unsafe-inline'"] },
    },
  },
  vite: {
    plugins: [tailwindcss()],
  },
});
