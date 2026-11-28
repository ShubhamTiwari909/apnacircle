import type { APIRoute } from 'astro';
import { PRIVATE_NOINDEX_PREFIXES } from '../lib/security-headers.js';
import { publicUrl } from '../lib/seo.js';

export const prerender = true;

export const GET: APIRoute = ({ site }) => {
  const lines = ['User-agent: *'];
  if (site) {
    for (const prefix of PRIVATE_NOINDEX_PREFIXES) {
      lines.push(`Disallow: ${prefix}$`, `Disallow: ${prefix}/`, `Disallow: ${prefix}?`);
    }
    lines.push('Disallow: /*/people$', 'Disallow: /*/people/', 'Disallow: /*/people?', '', `Sitemap: ${publicUrl(site, '/sitemap.xml')}`);
  } else {
    lines.push('Disallow: /');
  }
  return new Response(`${lines.join('\n')}\n`, { headers: { 'Content-Type': 'text/plain; charset=utf-8' } });
};
