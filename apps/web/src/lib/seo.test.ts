import { describe, expect, it } from 'vitest';
import { articleJsonLd, breadcrumbJsonLd, publicUrl, siteOrigin, sitemapXml, verificationToken } from './seo.js';

const site = new URL('https://apnacircle.example.com');

describe('canonical URLs and sitemap', () => {
  it('uses only a configured public HTTPS origin', () => {
    expect(siteOrigin('https://apnacircle.example.com/')).toBe(site.origin);
    for (const value of [undefined, 'https://apnacircle.example', 'http://localhost:4321', 'https://user@host.example.com', 'https://host.example.com/path', 'https://host.example.com/?x=y']) {
      expect(siteOrigin(value)).toBeUndefined();
    }
    expect(publicUrl(site, '//outside.example.net/')).toBe('https://apnacircle.example.com//outside.example.net');
  });

  it('uses clean canonical paths and writes absolute, escaped, deduplicated sitemap URLs', () => {
    expect(sitemapXml(site, ['/saharanpur/', '/saharanpur', '/a&b'])).toContain('<loc>https://apnacircle.example.com/a&amp;b</loc>');
    expect(sitemapXml(site, ['/saharanpur/', '/saharanpur']).match(/<loc>/g)).toHaveLength(1);
    expect(sitemapXml(site, ['/sitemap-pages.xml'], true)).toContain('<sitemap><loc>https://apnacircle.example.com/sitemap-pages.xml</loc></sitemap>');
    expect(sitemapXml(undefined, ['/private'])).not.toContain('/private');
  });

  it('gives the current breadcrumb the same URL as the canonical page', () => {
    const canonical = publicUrl(site, '/saharanpur/blog/walks/');
    expect(breadcrumbJsonLd(site, [{ label: 'Cities', path: '/cities' }, { label: 'Walks' }], canonical).itemListElement[1]?.item).toBe(canonical);
    const article = articleJsonLd(site, canonical, { title: 'Walks', description: 'Local outings', author: 'ApnaCircle Editorial' });
    expect(article.author).toEqual({ '@type': 'Organization', name: 'ApnaCircle Editorial' });
    expect(article.mainEntityOfPage).toBe(canonical);
  });

  it('accepts only the Search Console token value', () => {
    expect(verificationToken(' abc_DEF-123 ')).toBe('abc_DEF-123');
    expect(verificationToken('<meta name="google-site-verification" content="abc">')).toBeUndefined();
  });
});
