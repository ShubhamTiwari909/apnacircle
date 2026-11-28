# Technical SEO and Search Console

## Local setup

1. Use Node 24 and the repository’s pnpm version. Run `pnpm install --frozen-lockfile` from the repository root.
2. Copy `.env.example` to `apps/web/.env`. Keep `PUBLIC_SITE_URL=http://localhost:4321` and leave `PUBLIC_GOOGLE_SITE_VERIFICATION` empty. The public editorial pages work without Supabase. Unconfigured builds include `noindex` metadata and a `robots.txt` that disallows crawling.
3. For local meetups and member features, set `PUBLIC_SUPABASE_URL` to your Supabase Project URL and `PUBLIC_SUPABASE_ANON_KEY` to its legacy `anon` JWT. Use **Connect** and **Settings → API Keys** for a hosted project. For a new local stack, run `npx supabase init` if `supabase/config.toml` is absent, then `npx supabase start`. Run `npx supabase status` for the local API URL and key, and `npx supabase migration up --local` to apply pending migrations. The local API normally listens at `http://127.0.0.1:54321`. Keep service-role keys out of the web app.
4. For member sign-in, configure the Google provider in Supabase Authentication with a Google OAuth Web client. Use the callback from the Supabase provider settings as a Google authorized redirect. Add `http://localhost:4321/me/profile/auth` to the redirect allowlist in Supabase. For a local stack, configure `[auth.external.google]` in `supabase/config.toml` using environment references for the client ID and secret and set `auth.additional_redirect_urls` to include the same web callback before starting Supabase.
5. Use the example Turnstile keys for local feedback testing. Configure a widget for the final hostname when deploying. Set the widget site key as `PUBLIC_TURNSTILE_SITE_KEY` and its secret as `TURNSTILE_SECRET_KEY`.
6. Run `pnpm dev` and open `http://localhost:4321`.

### Optional Supabase Edge Function variables

Set these in the Edge Function environment when testing scheduled jobs or delivery.

| Variable | Where to get the value |
| --- | --- |
| `CRON_SECRET` | Generate with `openssl rand -hex 32`. Use the same value for the database’s `app.cron_secret` and the Edge Functions. |
| `SITE_URL` | Use the deployed web origin for links in email and push notifications. |
| `RESEND_API_KEY`, `FROM_EMAIL` | Create the key in Resend and choose a sender address on your verified domain. |
| `VAPID_PUBLIC_KEY`, `VAPID_PRIVATE_KEY`, `VAPID_SUBJECT` | Generate the key pair with `npx web-push generate-vapid-keys`. Use a `mailto:` contact for the subject. |
| `MODERATION_INBOX_EMAIL`, `GRIEVANCE_INBOX_EMAIL` | Use the inbox addresses your moderation and grievance teams monitor. |

## Deploy on Vercel

1. Sign in to [Vercel](https://vercel.com/dashboard) and import the GitHub repository. Set the project root to `apps/web`, choose the **Astro** preset and Node **24.x**, and enable **Include source files outside the Root Directory** so Vercel can read the workspace packages and editorial content. Keep Output Directory at its default. The app selects the Vercel adapter during a Vercel build. Local and Cloudflare builds still use the Cloudflare adapter by default.
2. Apply migration `023_phase8_meetup_sitemap.sql` and any earlier pending migrations to the hosted Supabase database. In **Vercel → Project → Settings → Environment Variables**, add the hosted `PUBLIC_SUPABASE_URL` and `PUBLIC_SUPABASE_ANON_KEY` for the environments you want to test. Set your Turnstile keys for feedback and add the deployed `/me/profile/auth` URL to the Supabase Auth redirect allowlist for member sign-in. Keep secrets in the project settings and Supabase Edge Function environment.
3. Check a preview, then deploy to Production. Keep **Automatically expose System Environment Variables** enabled. Without an explicit `PUBLIC_SITE_URL`, the production build uses Vercel’s `VERCEL_PROJECT_PRODUCTION_URL`. If you add a custom domain, set `PUBLIC_SITE_URL` to its HTTPS origin in the **Production** environment and redeploy. Preview builds carry `noindex` and suppress the Search Console verification tag.
4. On the production origin, confirm that `/robots.txt` advertises `/sitemap.xml` and both child sitemaps return HTTP 200. The editorial sitemap is built from published content and the meetup sitemap reads current, approved public meetups from Supabase.

To deploy the current local checkout, run `npx vercel login` and `npx vercel link` from the repository root. Select the configured project. Run `npx vercel deploy` for a preview and `npx vercel deploy --prod` to publish once the production environment is ready. Vercel uploads the local source for these commands, including uncommitted changes.

## Google Search Console

1. In [Google Search Console](https://search.google.com/search-console), add a **URL-prefix property** for the exact production origin, including `https://`. Select **HTML tag** and copy the token from the tag’s `content` attribute.
2. Set `PUBLIC_GOOGLE_SITE_VERIFICATION` to that token in the Vercel **Production** environment and redeploy. Confirm the tag in the production homepage source, then select **Verify** in Search Console. Keep the token in place after verification.
3. Open **Sitemaps**, submit `sitemap.xml`, and inspect the homepage, a city guide, and a current public meetup. Use [Rich Results Test](https://search.google.com/test/rich-results) to check the rendered structured data.

The sitemap omits member pages, drafts, archived content, filtered URLs, and past or cancelled meetups. Legal drafts and empty category pages carry `noindex`. Approved meetup detail pages remain reachable after their search metadata expires.

## Optional analytics

Set `POSTHOG_PROJECT_KEY` in the Vercel Production environment to the project API key from an EU PostHog project after the privacy notice and retention settings are approved. Keep the project’s data retention to the period stated in the notice. Without a key, the website leaves optional analytics off.

The first-visit banner and **Cookies & Analytics** page set the browser’s choice. Agreeing enables anonymous counts of public meetup views and successfully saved feedback. The integration sends only the event name and a random browser identifier, using the EU ingestion endpoint. Turning analytics off removes that identifier from the browser and stops future events.

## Browser journeys

Run `pnpm exec playwright install chromium` once, then `pnpm test:e2e` from the repository root. The suite builds the Vercel app, runs it on port 4173, and uses local fixtures for Google, Supabase, Turnstile, and PostHog. It checks successful and cancelled sign-in, feedback persistence and rejection, and analytics opt-in and withdrawal. It requires no service credentials. Live verification of provider credentials is a separate check.
