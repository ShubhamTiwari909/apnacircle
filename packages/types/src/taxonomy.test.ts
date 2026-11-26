import { describe, expect, it } from 'vitest';
import {
  ACTIVE_CITIES,
  CATEGORIES,
  CITIES,
  getCategoryBySlug,
  getCityBySlug,
  isValidCategorySlug,
  isValidCitySlug,
} from './taxonomy.js';

describe('taxonomy single source of truth', () => {
  it('activates only Saharanpur at launch', () => {
    expect(ACTIVE_CITIES.map((c) => c.slug)).toEqual(['saharanpur']);
    expect(CITIES.length).toBeGreaterThanOrEqual(6);
  });

  it('excludes trekking from V1 categories (D8)', () => {
    expect(CATEGORIES.some((c) => c.slug.includes('trekking'))).toBe(false);
    expect(isValidCategorySlug('places-to-visit')).toBe(true);
    expect(isValidCategorySlug('trekking')).toBe(false);
  });

  it('resolves known cities and categories by slug', () => {
    expect(getCityBySlug('saharanpur')?.name).toBe('Saharanpur');
    expect(getCategoryBySlug('cafes-and-restaurants')?.featuredRoute).toBe(true);
    expect(isValidCitySlug('unknown-city')).toBe(false);
  });
});
