import { getCollection } from 'astro:content';
import { ACTIVE_CITIES } from '@apnacircle/types';

const activeCitySlugs = new Set(ACTIVE_CITIES.map(({ slug }) => slug));

export function publishedArticles() {
  return getCollection('articles', ({ data }) => data.status === 'published' && activeCitySlugs.has(data.citySlug));
}

export function publishedPlaces(city?: string) {
  return getCollection('places', ({ data }) => data.status === 'published' && activeCitySlugs.has(data.citySlug) &&
    (city === undefined || data.citySlug === city));
}

export function placePath(city: string, slug: string): string {
  return `/${city}/places/${encodeURIComponent(slug)}`;
}

export function articlePath(city: string, slug: string): string {
  return `/${city}/blog/${encodeURIComponent(slug)}`;
}
