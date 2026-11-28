import type { APIRoute } from 'astro';
import { getRuntimePublicApiConfig } from '../lib/server-config.js';
import { z } from 'zod';
import { ACTIVE_CITIES } from '@apnacircle/types';
import { callPublicRpc } from '../lib/meetups.js';
import { sitemapResponse, sitemapXml } from '../lib/seo.js';

export const prerender = false;

const slugs = z.array(z.object({ citySlug: z.string(), slug: z.string().regex(/^[a-z0-9-]{1,80}$/) })).max(50000);
const activeCities = new Set(ACTIVE_CITIES.map(({ slug }) => slug));

export const GET: APIRoute = async ({ site }) => {
  if (!site) return new Response(null, { status: 404 });
  const config = getRuntimePublicApiConfig();
  const result = config && await callPublicRpc(config, 'list_public_meetup_sitemap', {}, slugs, fetch);
  if (!result || !result.ok) return new Response(null, { status: 503, headers: { 'Cache-Control': 'no-store' } });
  const paths = result.data.filter(({ citySlug }) => activeCities.has(citySlug)).map(({ citySlug, slug }) => `/${citySlug}/meetups/${slug}`);
  return sitemapResponse(sitemapXml(site, paths));
};
