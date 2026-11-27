import { z } from 'zod';
import {
  CITIES,
  decodeMeetupCursor,
  encodeMeetupCursor,
  isMeetupDateFilter,
  meetupDateRange,
  publicMeetupDetailSchema,
  publicMeetupSchema,
  type MeetupDateFilter,
  type PublicMeetup,
  type PublicMeetupDetail,
} from '@apnacircle/types';

// Server-side reads of the public meetup RPCs. The browser never talks to the database; the page
// is rendered on the Worker with the public (anon) key, which can only call the two public RPCs.

export type FetchLike = (input: string, init?: RequestInit) => Promise<Response>;

export interface PublicApiConfig {
  url: string;
  anonKey: string;
}

export function getPublicApiConfig(env: Record<string, string | undefined>): PublicApiConfig | null {
  const url = env.PUBLIC_SUPABASE_URL?.trim().replace(/\/+$/, '');
  const anonKey = env.PUBLIC_SUPABASE_ANON_KEY?.trim();
  if (!url || !anonKey) return null;
  const isLocal = /^http:\/\/(localhost|127\.0\.0\.1)(:\d+)?$/.test(url);
  if (!url.startsWith('https://') && !isLocal) return null;
  return { url, anonKey };
}

export type ApiResult<T> = { ok: true; data: T } | { ok: false };

async function callPublicRpc<T>(
  config: PublicApiConfig,
  fn: string,
  args: Record<string, unknown>,
  schema: z.ZodType<T>,
  fetchFn: FetchLike,
): Promise<ApiResult<T>> {
  try {
    const response = await fetchFn(`${config.url}/rest/v1/rpc/${fn}`, {
      method: 'POST',
      headers: {
        apikey: config.anonKey,
        Authorization: `Bearer ${config.anonKey}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify(args),
      signal: AbortSignal.timeout(4000),
    });
    if (!response.ok) return { ok: false };
    const parsed = schema.safeParse(await response.json());
    return parsed.success ? { ok: true, data: parsed.data } : { ok: false };
  } catch {
    return { ok: false };
  }
}

export const LISTING_PAGE_SIZE = 12;

export interface ListingQuery {
  citySlug: string | null;
  categorySlug: string | null;
  when: MeetupDateFilter;
  cursor: { startsAt: string; id: string } | null;
}

export function parseListingQuery(
  searchParams: URLSearchParams,
  citySlug: string | null,
  validCategorySlugs: readonly string[],
): ListingQuery {
  const category = searchParams.get('category');
  const when = searchParams.get('when');
  return {
    citySlug,
    categorySlug: category && validCategorySlugs.includes(category) ? category : null,
    when: isMeetupDateFilter(when) ? when : 'any',
    cursor: decodeMeetupCursor(searchParams.get('after')),
  };
}

export interface MeetupListing {
  meetups: PublicMeetup[];
  nextCursor: string | null;
}

export async function listPublicMeetups(
  config: PublicApiConfig,
  query: ListingQuery,
  fetchFn: FetchLike = fetch,
  now: Date = new Date(),
): Promise<ApiResult<MeetupListing>> {
  const range = meetupDateRange(query.when, now);
  const result = await callPublicRpc(
    config,
    'list_public_meetups',
    {
      p_city_slug: query.citySlug,
      p_category_slug: query.categorySlug,
      p_from: range.from,
      p_to: range.to,
      p_after_starts_at: query.cursor?.startsAt ?? null,
      p_after_id: query.cursor?.id ?? null,
      p_limit: LISTING_PAGE_SIZE + 1, // one extra row tells us whether another page exists
    },
    z.array(publicMeetupSchema),
    fetchFn,
  );
  if (!result.ok) return result;

  const hasMore = result.data.length > LISTING_PAGE_SIZE;
  const meetups = result.data.slice(0, LISTING_PAGE_SIZE);
  const last = meetups[meetups.length - 1];
  return {
    ok: true,
    data: { meetups, nextCursor: hasMore && last ? encodeMeetupCursor(last.starts_at, last.id) : null },
  };
}

export async function getPublicMeetup(
  config: PublicApiConfig,
  citySlug: string,
  slug: string,
  fetchFn: FetchLike = fetch,
): Promise<ApiResult<PublicMeetupDetail | null>> {
  const result = await callPublicRpc(
    config,
    'get_public_meetup',
    { p_city_slug: citySlug, p_slug: slug },
    z.array(publicMeetupDetailSchema),
    fetchFn,
  );
  return result.ok ? { ok: true, data: result.data[0] ?? null } : result;
}

// ---------------------------------------------------------------------------------------------
// Presentation helpers
// ---------------------------------------------------------------------------------------------

const startFormat = new Intl.DateTimeFormat('en-IN', {
  weekday: 'short',
  day: 'numeric',
  month: 'short',
  hour: 'numeric',
  minute: '2-digit',
  timeZone: 'Asia/Kolkata',
});

const timeFormat = new Intl.DateTimeFormat('en-IN', {
  hour: 'numeric',
  minute: '2-digit',
  timeZone: 'Asia/Kolkata',
});

export function formatMeetupWhen(startsAt: string, endsAt: string | null): string {
  const start = startFormat.format(new Date(startsAt));
  return endsAt ? `${start} – ${timeFormat.format(new Date(endsAt))} IST` : `${start} IST`;
}

export function isFull(meetup: Pick<PublicMeetup, 'capacity' | 'attendee_count'>): boolean {
  return meetup.attendee_count >= meetup.capacity;
}

export function spotsLeft(meetup: Pick<PublicMeetup, 'capacity' | 'attendee_count'>): number {
  return Math.max(meetup.capacity - meetup.attendee_count, 0);
}

// ---------------------------------------------------------------------------------------------
// Event structured data: only for approved, accurate, current events (plan 3.8 / 10)
// ---------------------------------------------------------------------------------------------

export function buildEventJsonLd(
  meetup: PublicMeetupDetail,
  siteOrigin: string,
  now: Date = new Date(),
): Record<string, unknown> | null {
  if (meetup.status !== 'published') return null;
  const end = new Date(meetup.ends_at ?? meetup.starts_at);
  if (end.getTime() < now.getTime()) return null;

  const region = CITIES.find((c) => c.slug === meetup.city_slug)?.state;
  return {
    '@context': 'https://schema.org',
    '@type': 'Event',
    name: meetup.title,
    description: meetup.description.slice(0, 500),
    startDate: meetup.starts_at,
    ...(meetup.ends_at ? { endDate: meetup.ends_at } : {}),
    eventStatus: 'https://schema.org/EventScheduled',
    eventAttendanceMode: 'https://schema.org/OfflineEventAttendanceMode',
    location: {
      '@type': 'Place',
      name: meetup.venue_name,
      address: {
        '@type': 'PostalAddress',
        streetAddress: meetup.locality,
        addressLocality: meetup.city_name,
        ...(region ? { addressRegion: region } : {}),
        addressCountry: 'IN',
      },
    },
    organizer: { '@type': 'Person', name: meetup.host_display_name },
    maximumAttendeeCapacity: meetup.capacity,
    remainingAttendeeCapacity: spotsLeft(meetup),
    url: `${siteOrigin.replace(/\/+$/, '')}/${meetup.city_slug}/meetups/${meetup.slug}`,
  };
}

/** JSON for an inline `application/ld+json` block that cannot break out of its <script> tag. */
export function serializeJsonLd(data: Record<string, unknown>): string {
  return JSON.stringify(data)
    .replace(/</g, '\\u003c')
    .replace(/>/g, '\\u003e')
    .replace(/&/g, '\\u0026')
    .replace(new RegExp('\\u2028', 'g'), '\\u2028')
    .replace(new RegExp('\\u2029', 'g'), '\\u2029');
}
