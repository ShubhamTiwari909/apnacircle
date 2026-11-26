import { describe, expect, it } from 'vitest';
import { en, t } from './index.js';

describe('@apnacircle/i18n', () => {
  it('interpolates named parameters cleanly', () => {
    expect(t('city.categoriesHeading', { city: 'Saharanpur' })).toBe(
      'Categories in Saharanpur',
    );
  });

  it('contains non-empty values for every key', () => {
    for (const [k, v] of Object.entries(en)) {
      expect(typeof v, `key ${k}`).toBe('string');
      expect(v.trim().length, `key ${k}`).toBeGreaterThan(0);
    }
  });
});
