import type { APIRoute } from 'astro';
import { sitemapResponse, sitemapXml } from '../lib/seo.js';

export const prerender = false;

export const GET: APIRoute = ({ site }) => site
  ? sitemapResponse(sitemapXml(site, ['/sitemap-pages.xml', '/sitemap-meetups.xml'], true))
  : new Response(null, { status: 404 });
