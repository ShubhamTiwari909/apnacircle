import { FiChevronDown, FiMapPin, FiMenu } from 'react-icons/fi';
import { t } from '@apnacircle/i18n';
import { CITIES } from '@apnacircle/types';

export interface MobileNavigationProps {
  currentPath: string;
}

export const PRIMARY_NAV_LINKS = [
  { href: '/saharanpur', key: 'nav.cities' as const },
  { href: '/meetups', key: 'nav.meetups' as const },
  { href: '/places', key: 'nav.places' as const },
  { href: '/people', key: 'nav.people' as const },
  { href: '/safety', key: 'nav.safety' as const },
  { href: '/about', key: 'nav.about' as const },
  { href: '/feedback', key: 'nav.feedback' as const },
];

export function isNavigationActive(pathname: string, href: string): boolean {
  const [, section, subsection] = pathname.split('/');
  if (section === 'cities') return href === '/saharanpur';
  if (CITIES.some((city) => city.slug === section)) {
    const cityRoute = ['people', 'places', 'meetups'].includes(subsection ?? '') ? `/${subsection}` : '/saharanpur';
    return href === cityRoute;
  }
  return pathname === href || pathname.startsWith(`${href}/`);
}

export function MobileNavigation({ currentPath }: MobileNavigationProps) {
  return (
    <details name="site-header-menu" className="relative xl:hidden">
      <summary
        aria-label={t('nav.menuLabel')}
        className="flex size-11 cursor-pointer list-none items-center justify-center rounded-xl border border-[var(--ac-border)] text-[var(--ac-ink)] hover:bg-[var(--ac-surface-muted)] focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-[var(--ac-accent)] [&::-webkit-details-marker]:hidden"
      >
        <FiMenu size={20} aria-hidden="true" />
      </summary>
      <nav
        aria-label={t('nav.primary')}
        className="absolute right-0 top-full z-30 mt-2 w-56 rounded-xl border border-[var(--ac-border)] bg-[var(--ac-surface)] p-1.5"
      >
        <ul>
          {PRIMARY_NAV_LINKS.map(({ href, key }) => {
            const active = isNavigationActive(currentPath, href);
            return (
              <li key={href}>
                <a
                  href={href}
                  aria-current={active ? 'page' : undefined}
                  className={`flex min-h-11 items-center rounded-lg px-3 text-sm font-medium focus-visible:outline-2 focus-visible:-outline-offset-2 focus-visible:outline-[var(--ac-accent)] ${
                    active
                      ? 'bg-[var(--ac-accent-soft)] text-[var(--ac-accent)]'
                      : 'text-[var(--ac-ink)] hover:bg-[var(--ac-surface-muted)]'
                  }`}
                >
                  {t(key)}
                </a>
              </li>
            );
          })}
        </ul>
        <div className="mt-1 border-t border-[var(--ac-border)] px-2 pt-2">
          <ThemeSwitcher />
        </div>
      </nav>
    </details>
  );
}

export function CitySwitcher({ activeSlug = 'saharanpur' }: { activeSlug?: string }) {
  const activeCity = CITIES.find((city) => city.slug === activeSlug && city.active) ??
    CITIES.find((city) => city.active);
  if (!activeCity) return null;

  return (
    <details name="site-header-menu" className="group relative">
      <summary
        aria-label={`${t('switcher.cityLabel')}: ${activeCity.name}`}
        className="flex min-h-11 min-w-11 cursor-pointer list-none items-center justify-center gap-1.5 whitespace-nowrap rounded-xl border border-[var(--ac-border)] px-2.5 text-sm font-medium text-[var(--ac-ink)] hover:bg-[var(--ac-surface-muted)] focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-[var(--ac-accent)] [&::-webkit-details-marker]:hidden"
      >
        <FiMapPin size={16} className="text-[var(--ac-accent)]" aria-hidden="true" />
        <span className="hidden min-[400px]:inline">{activeCity.name}</span>
        <FiChevronDown size={14} className="hidden text-[var(--ac-ink-muted)] group-open:rotate-180 min-[400px]:block" aria-hidden="true" />
      </summary>
      <ul className="absolute left-1/2 top-full z-30 mt-2 w-52 -translate-x-1/2 rounded-xl border border-[var(--ac-border)] bg-[var(--ac-surface)] p-1.5 min-[400px]:left-auto min-[400px]:right-0 min-[400px]:translate-x-0">
        {CITIES.map((city) => (
          <li key={city.slug}>
            {city.active ? (
              <a
                href={`/${city.slug}`}
                aria-current={city.slug === activeCity.slug ? 'location' : undefined}
                className="flex min-h-11 items-center rounded-lg px-3 text-sm font-medium text-[var(--ac-ink)] hover:bg-[var(--ac-surface-muted)] focus-visible:outline-2 focus-visible:-outline-offset-2 focus-visible:outline-[var(--ac-accent)] aria-[current=location]:bg-[var(--ac-accent-soft)] aria-[current=location]:text-[var(--ac-accent)]"
              >
                {city.name}
              </a>
            ) : (
              <span className="flex min-h-10 items-center justify-between gap-2 px-3 text-sm text-[var(--ac-ink-muted)]">
                {city.name}
                <span className="text-xs">{t('switcher.upcomingSuffix')}</span>
              </span>
            )}
          </li>
        ))}
      </ul>
    </details>
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

export function ThemeSwitcher() {
  return (
    <label className="flex items-center justify-between gap-2 whitespace-nowrap px-1 text-sm font-medium text-[var(--ac-ink-muted)]">
      <span>{t('theme.label')}</span>
      <select
        data-theme-select
        className="min-h-11 rounded-xl border border-[var(--ac-border-strong)] bg-[var(--ac-surface)] px-2 text-sm font-semibold text-[var(--ac-ink)]"
      >
        <option value="sage">{t('theme.sage')}</option>
        <option value="blue">{t('theme.blue')}</option>
        <option value="pink">{t('theme.pink')}</option>
      </select>
    </label>
  );
}
