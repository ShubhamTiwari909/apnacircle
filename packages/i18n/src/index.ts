import en from './locales/en.json' with { type: 'json' };

export type Locale = 'en';
export type MessageCatalogue = typeof en;
export type MessageKey = keyof MessageCatalogue;

const CATALOGUES: Record<Locale, MessageCatalogue> = {
  en,
};

export function getLocaleMessages(locale: Locale = 'en'): MessageCatalogue {
  return CATALOGUES[locale];
}

export function t(
  key: MessageKey,
  vars?: Record<string, string | number>,
  locale: Locale = 'en',
): string {
  const template = CATALOGUES[locale][key];
  if (!vars) return template;

  return template.replace(/\{([a-zA-Z0-9_]+)\}/g, (_match, name: string) => {
    const value = vars[name];
    return value === undefined ? `{${name}}` : String(value);
  });
}

export { en };
