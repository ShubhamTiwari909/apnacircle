export const socialImage = '/apnacircle-social.png';
const sitemapNamespace = 'http://www.sitemaps.org/schemas/sitemap/0.9';

export function siteOrigin(value: string | undefined): string | undefined {
  if (!value) return undefined;
  try {
    const url = new URL(value);
    if (url.protocol === 'https:' && url.pathname === '/' && !url.username && !url.password &&
      !url.search && !url.hash && !url.port && url.hostname.includes('.') &&
      !/\.(example|test|local|invalid|localhost)$/.test(url.hostname) && !/^\d+\.\d+\.\d+\.\d+$/.test(url.hostname)) {
      return url.origin;
    }
  } catch {
    return undefined;
  }
  return undefined;
}

export function publicUrl(site: URL | string, path: string): string {
  const url = new URL(site);
  url.pathname = path.replace(/\/+$/, '') || '/';
  url.search = '';
  url.hash = '';
  return url.href;
}

export function verificationToken(value: string | undefined): string | undefined {
  const token = value?.trim();
  return token && /^[A-Za-z0-9_-]{1,200}$/.test(token) ? token : undefined;
}

export interface Crumb {
  label: string;
  path?: string;
}

export function breadcrumbJsonLd(site: URL, crumbs: readonly Crumb[], canonical: string) {
  return {
    '@context': 'https://schema.org',
    '@type': 'BreadcrumbList',
    itemListElement: crumbs.map(({ label, path }, index) => ({
      '@type': 'ListItem', position: index + 1, name: label, item: path ? publicUrl(site, path) : canonical,
    })),
  };
}

export function siteJsonLd(site: URL, name: string, description: string) {
  const url = publicUrl(site, '/');
  const publisher = { '@id': `${url}#organization` };
  return {
    '@context': 'https://schema.org',
    '@graph': [
      { '@type': 'Organization', ...publisher, name, url },
      { '@type': 'WebSite', '@id': `${url}#website`, name, url, description, publisher, inLanguage: 'en' },
    ],
  };
}

export function articleJsonLd(site: URL, url: string, article: { title: string; description: string; author: string }) {
  const home = publicUrl(site, '/');
  return {
    '@context': 'https://schema.org',
    '@type': 'Article',
    mainEntityOfPage: url,
    headline: article.title,
    description: article.description,
    author: { '@type': article.author === 'ApnaCircle Editorial' ? 'Organization' : 'Person', name: article.author },
    publisher: { '@type': 'Organization', '@id': `${home}#organization`, name: 'ApnaCircle', url: home },
    inLanguage: 'en',
  };
}

function escapeXml(value: string): string {
  return value.replace(/[&<>"']/g, (character) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&apos;' })[character] ?? character);
}

export function sitemapXml(site: URL | undefined, paths: Iterable<string>, index = false): string {
  return `<?xml version="1.0" encoding="UTF-8"?>\n${site ? renderUrls(site, paths, index) : `<${index ? 'sitemapindex' : 'urlset'} xmlns="${sitemapNamespace}"/>`}\n`;
}

function renderUrls(site: URL, paths: Iterable<string>, index: boolean): string {
  const root = index ? 'sitemapindex' : 'urlset';
  const item = index ? 'sitemap' : 'url';
  const urls = [...new Set([...paths].map((path) => publicUrl(site, path)))].sort();
  return `<${root} xmlns="${sitemapNamespace}">\n${urls.map((url) => `  <${item}><loc>${escapeXml(url)}</loc></${item}>\n`).join('')}</${root}>`;
}

export function sitemapResponse(xml: string, cacheControl = 'public, max-age=300'): Response {
  return new Response(xml, { headers: { 'Content-Type': 'application/xml; charset=utf-8', 'Cache-Control': cacheControl } });
}
