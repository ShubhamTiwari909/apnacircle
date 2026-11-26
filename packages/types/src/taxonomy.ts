import { z } from 'zod';
import citiesData from '../data/cities.json' with { type: 'json' };
import categoriesData from '../data/categories.json' with { type: 'json' };

export const citySchema = z.object({
  slug: z.string().regex(/^[a-z0-9-]+$/),
  name: z.string().min(1),
  state: z.string().min(1),
  country: z.literal('IN'),
  active: z.boolean(),
  rolloutOrder: z.number().int().positive(),
  timezone: z.literal('Asia/Kolkata'),
});

export const categorySchema = z.object({
  slug: z.string().regex(/^[a-z0-9-]+$/),
  name: z.string().min(1),
  featuredRoute: z.boolean(),
  kind: z.enum(['place', 'activity']),
});

export type City = z.infer<typeof citySchema>;
export type Category = z.infer<typeof categorySchema>;

export const CITIES: readonly City[] = z.array(citySchema).parse(citiesData);
export const ACTIVE_CITIES: readonly City[] = CITIES.filter((c) => c.active);
export const CATEGORIES: readonly Category[] = z.array(categorySchema).parse(categoriesData);

export const CITY_SLUGS = CITIES.map((c) => c.slug) as [string, ...string[]];
export const CATEGORY_SLUGS = CATEGORIES.map((c) => c.slug) as [string, ...string[]];

export const citySlugSchema = z.enum(CITY_SLUGS);
export const categorySlugSchema = z.enum(CATEGORY_SLUGS);

export function isValidCitySlug(slug: string): boolean {
  return CITIES.some((c) => c.slug === slug);
}

export function isValidCategorySlug(slug: string): boolean {
  return CATEGORIES.some((c) => c.slug === slug);
}

export function getCityBySlug(slug: string): City | undefined {
  return CITIES.find((c) => c.slug === slug);
}

export function getCategoryBySlug(slug: string): Category | undefined {
  return CATEGORIES.find((c) => c.slug === slug);
}
