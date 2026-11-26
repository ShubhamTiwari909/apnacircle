import { defineCollection, z } from 'astro:content';
import { glob } from 'astro/loaders';
import {
  articleContentSchema,
  categoryContentSchema,
  cityContentSchema,
  faqContentSchema,
  landingPageContentSchema,
  placeContentSchema,
} from '@apnacircle/types';

const cities = defineCollection({
  loader: glob({ pattern: '**/*.md', base: '../../content/cities' }),
  schema: cityContentSchema,
});

const categories = defineCollection({
  loader: glob({ pattern: '**/*.md', base: '../../content/categories' }),
  schema: categoryContentSchema,
});

const places = defineCollection({
  loader: glob({ pattern: '**/*.md', base: '../../content/places' }),
  schema: placeContentSchema,
});

const articles = defineCollection({
  loader: glob({ pattern: '**/*.md', base: '../../content/articles' }),
  schema: articleContentSchema,
});

const faqs = defineCollection({
  loader: glob({ pattern: '**/*.md', base: '../../content/faqs' }),
  schema: faqContentSchema,
});

const landingPages = defineCollection({
  loader: glob({ pattern: '**/*.md', base: '../../content/landingPages' }),
  schema: landingPageContentSchema,
});

const policies = defineCollection({
  loader: glob({ pattern: '0[1-8]-*.md', base: '../../apnacircle-policies' }),
  schema: z.object({}).passthrough(),
});

export const collections = {
  cities,
  categories,
  places,
  articles,
  faqs,
  landingPages,
  policies,
};
