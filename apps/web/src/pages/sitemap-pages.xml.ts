import type { APIRoute } from 'astro';
import { getCollection } from 'astro:content';
import { ACTIVE_CITIES } from '@apnacircle/types';
import { articlePath, placePath, publishedArticles, publishedPlaces } from '../lib/editorial.js';
import { sitemapResponse, sitemapXml } from '../lib/seo.js';

export const prerender = true;

export const GET: APIRoute = async ({ site }) => {
  if (!site) return sitemapResponse(sitemapXml(undefined, []));
  const [cities, categories, places, articles] = await Promise.all([
    getCollection('cities', ({ data }) => data.status === 'published'),
    getCollection('categories', ({ data }) => data.status === 'published'),
    publishedPlaces(),
    publishedArticles(),
  ]);
  const paths = ['/', '/about', '/cities'];
  if (ACTIVE_CITIES.length > 1) paths.push('/meetups');
  if (places.length && ACTIVE_CITIES.length > 1) paths.push('/places');
  for (const { slug } of ACTIVE_CITIES) {
    if (cities.some(({ data }) => data.slug === slug)) paths.push(`/${slug}`);
    paths.push(`/${slug}/meetups`);
    if (places.some(({ data }) => data.citySlug === slug)) paths.push(`/${slug}/places`);
    paths.push(...categories.filter(({ data }) => data.citySlug === slug).map(({ data }) => `/${slug}/${data.slug}`));
    paths.push(...places.filter(({ data }) => data.citySlug === slug).map(({ data }) => `/${slug}/${data.categorySlug}`));
  }
  paths.push(...places.map(({ id, data }) => placePath(data.citySlug, id)));
  paths.push(...articles.map(({ id, data }) => articlePath(data.citySlug, id)));
  return sitemapResponse(sitemapXml(site, paths));
};
