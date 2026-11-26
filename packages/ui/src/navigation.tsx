import { useState } from 'react';
import { t } from '@apnacircle/i18n';
import { CITIES } from '@apnacircle/types';

export interface MobileNavigationProps {
  currentPath: string;
}

const NAV_LINKS = [
  { href: '/saharanpur', key: 'nav.cities' as const },
  { href: '/meetups', key: 'nav.meetups' as const },
  { href: '/places', key: 'nav.places' as const },
  { href: '/people', key: 'nav.people' as const },
  { href: '/safety', key: 'nav.safety' as const },
  { href: '/about', key: 'nav.about' as const },
  { href: '/feedback', key: 'nav.feedback' as const },
];

export function MobileNavigation({ currentPath }: MobileNavigationProps) {
  const [open, setOpen] = useState(false);

  return (
    <div className="md:hidden">
      <button
        type="button"
        aria-expanded={open}
        aria-controls="mobile-nav-drawer"
        onClick={() => setOpen((prev) => !prev)}
        className="inline-flex min-h-10 items-center justify-center rounded-xl border border-[var(--ac-border)] bg-[var(--ac-surface)] px-3 py-2 text-sm font-medium text-[var(--ac-ink)] hover:bg-[var(--ac-surface-muted)]"
      >
        {open ? t('nav.menuClose') : t('nav.menuOpen')}
      </button>

      {open ? (
        <nav
          id="mobile-nav-drawer"
          aria-label={t('nav.home')}
          className="absolute inset-x-0 top-full z-40 border-b border-[var(--ac-border)] bg-[var(--ac-surface)] px-4 py-4 shadow-lg"
        >
          <ul className="flex flex-col gap-2">
            {NAV_LINKS.map((item) => {
              const active =
                currentPath === item.href ||
                (item.href !== '/' && currentPath.startsWith(item.href));
              return (
                <li key={item.href}>
                  <a
                    href={item.href}
                    aria-current={active ? 'page' : undefined}
                    onClick={() => setOpen(false)}
                    className={`block rounded-xl px-3 py-2 text-sm font-medium ${
                      active
                        ? 'bg-[var(--ac-accent-soft)] text-[var(--ac-accent)]'
                        : 'text-[var(--ac-ink)] hover:bg-[var(--ac-surface-muted)]'
                    }`}
                  >
                    {t(item.key)}
                  </a>
                </li>
              );
            })}
          </ul>
        </nav>
      ) : null}
    </div>
  );
}

export function CitySwitcher({ activeSlug = 'saharanpur' }: { activeSlug?: string }) {
  return (
    <div className="flex flex-wrap items-center gap-2 text-xs">
      <span className="font-medium text-[var(--ac-ink-muted)]">
        {t('switcher.cityLabel')}:
      </span>
      <ul className="flex flex-wrap items-center gap-1.5">
        {CITIES.map((city) =>
          city.active ? (
            <li key={city.slug}>
              <a
                href={`/${city.slug}`}
                aria-current={city.slug === activeSlug ? 'page' : undefined}
                className={`inline-flex items-center rounded-full px-2.5 py-1 font-medium ${
                  city.slug === activeSlug
                    ? 'bg-[var(--ac-accent)] text-white'
                    : 'border border-[var(--ac-border)] bg-[var(--ac-surface)] text-[var(--ac-ink)]'
                }`}
              >
                {city.name}
              </a>
            </li>
          ) : (
            <li key={city.slug}>
              <span className="inline-flex items-center rounded-full border border-[var(--ac-border)] bg-[var(--ac-surface-muted)] px-2.5 py-1 text-[var(--ac-ink-muted)]">
                {city.name} ({t('switcher.upcomingSuffix')})
              </span>
            </li>
          ),
        )}
      </ul>
    </div>
  );
}

export function LanguageSwitcher() {
  return (
    <div
      className="inline-flex items-center gap-1.5 rounded-full border border-[var(--ac-border)] bg-[var(--ac-surface)] px-3 py-1 text-xs text-[var(--ac-ink-muted)]"
      aria-label={t('switcher.languageLabel')}
    >
      <span className="font-semibold text-[var(--ac-ink)]">{t('switcher.english')}</span>
      <span aria-hidden="true">&middot;</span>
      <span>{t('switcher.hindiSoon')}</span>
    </div>
  );
}
