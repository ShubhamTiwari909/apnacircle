import { describe, expect, it, vi } from 'vitest';
import type { PublicMeetupDetail } from '@apnacircle/types';
import {
  buildEventJsonLd,
  getPublicApiConfig,
  getPublicMeetup,
  isFull,
  listPublicMeetups,
  parseListingQuery,
  serializeJsonLd,
  spotsLeft,
  LISTING_PAGE_SIZE,
  type FetchLike,
  type PublicApiConfig,
} from './meetups.js';

const config: PublicApiConfig = { url: 'https://example.supabase.co', anonKey: 'anon-key' };

function row(n: number, overrides: Record<string, unknown> = {}) {
  return {
    id: `00000000-0000-4000-8000-${String(n).padStart(12, '0')}`,
    slug: `ride-${n}`,
    city_slug: 'saharanpur',
    city_name: 'Saharanpur',
    category_slug: 'sports-and-fitness',
    category_name: 'Sports & Fitness',
    title: `Ride ${n}`,
    description: 'A relaxed group ride.',
    venue_name: 'Company Garden',
    locality: 'Civil Lines',
    starts_at: `2026-12-0${(n % 8) + 1}T04:30:00+00:00`,
    ends_at: `2026-12-0${(n % 8) + 1}T06:30:00+00:00`,
    capacity: 10,
    attendee_count: 2,
    women_only: false,
    join_mode: 'auto',
    host_display_name: 'Hari',
    ...overrides,
  };
}

const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status });

describe('getPublicApiConfig', () => {
  it('needs both values and an https url (http only for localhost)', () => {
    expect(getPublicApiConfig({})).toBeNull();
    expect(getPublicApiConfig({ PUBLIC_SUPABASE_URL: 'https://x.supabase.co' })).toBeNull();
    expect(getPublicApiConfig({ PUBLIC_SUPABASE_URL: 'http://evil.example', PUBLIC_SUPABASE_ANON_KEY: 'k' })).toBeNull();
    expect(getPublicApiConfig({ PUBLIC_SUPABASE_URL: 'http://127.0.0.1:54321', PUBLIC_SUPABASE_ANON_KEY: 'k' })).not.toBeNull();
    expect(getPublicApiConfig({ PUBLIC_SUPABASE_URL: 'https://x.supabase.co/', PUBLIC_SUPABASE_ANON_KEY: 'k' })?.url).toBe('https://x.supabase.co');
  });
});

describe('parseListingQuery', () => {
  it('ignores unknown categories, filters and bad cursors', () => {
    const q = parseListingQuery(new URLSearchParams('category=nope&when=yesterday&after=garbage'), 'saharanpur', ['sports-and-fitness']);
    expect(q).toEqual({ citySlug: 'saharanpur', categorySlug: null, when: 'any', cursor: null });
  });
  it('accepts valid ones', () => {
    const q = parseListingQuery(new URLSearchParams('category=sports-and-fitness&when=weekend'), null, ['sports-and-fitness']);
    expect(q.categorySlug).toBe('sports-and-fitness');
    expect(q.when).toBe('weekend');
  });
});

describe('listPublicMeetups', () => {
  it('calls the public RPC with only the anon key and paginates with a cursor', async () => {
    const rows = Array.from({ length: LISTING_PAGE_SIZE + 1 }, (_, i) => row(i + 1));
    const fetchFn = vi.fn<FetchLike>().mockResolvedValue(json(rows));
    const result = await listPublicMeetups(config, { citySlug: 'saharanpur', categorySlug: null, when: 'any', cursor: null }, fetchFn);

    expect(fetchFn).toHaveBeenCalledOnce();
    const [url, init] = fetchFn.mock.calls[0] as [string, RequestInit];
    expect(url).toBe('https://example.supabase.co/rest/v1/rpc/list_public_meetups');
    expect(init.headers).toMatchObject({ apikey: 'anon-key', Authorization: 'Bearer anon-key' });
    expect(JSON.parse(init.body as string)).toMatchObject({ p_city_slug: 'saharanpur', p_limit: LISTING_PAGE_SIZE + 1 });

    expect(result.ok).toBe(true);
    if (result.ok) {
      expect(result.data.meetups).toHaveLength(LISTING_PAGE_SIZE);
      expect(result.data.nextCursor).not.toBeNull();
    }
  });

  it('has no next page when the page is not full', async () => {
    const fetchFn = vi.fn<FetchLike>().mockResolvedValue(json([row(1), row(2)]));
    const result = await listPublicMeetups(config, { citySlug: null, categorySlug: null, when: 'any', cursor: null }, fetchFn);
    expect(result.ok && result.data.nextCursor).toBeNull();
  });

  it('fails closed on HTTP errors, network errors and unexpected shapes', async () => {
    const q = { citySlug: null, categorySlug: null, when: 'any', cursor: null } as const;
    expect((await listPublicMeetups(config, q, vi.fn<FetchLike>().mockResolvedValue(json({ message: 'boom' }, 500)))).ok).toBe(false);
    expect((await listPublicMeetups(config, q, vi.fn<FetchLike>().mockRejectedValue(new Error('offline')))).ok).toBe(false);
    expect((await listPublicMeetups(config, q, vi.fn<FetchLike>().mockResolvedValue(json([{ ...row(1), spot_note: 'secret', capacity: -1 }])))).ok).toBe(false);
  });
});

describe('getPublicMeetup', () => {
  it('returns null when there is no such meetup, and the meetup when there is', async () => {
    const none = await getPublicMeetup(config, 'saharanpur', 'x', vi.fn<FetchLike>().mockResolvedValue(json([])));
    expect(none).toEqual({ ok: true, data: null });
    const one = await getPublicMeetup(config, 'saharanpur', 'ride-1', vi.fn<FetchLike>().mockResolvedValue(json([{ ...row(1), status: 'published' }])));
    expect(one.ok && one.data?.slug).toBe('ride-1');
  });
});

describe('capacity helpers', () => {
  it('computes spots and fullness', () => {
    expect(spotsLeft({ capacity: 10, attendee_count: 3 })).toBe(7);
    expect(spotsLeft({ capacity: 5, attendee_count: 9 })).toBe(0);
    expect(isFull({ capacity: 5, attendee_count: 5 })).toBe(true);
    expect(isFull({ capacity: 5, attendee_count: 4 })).toBe(false);
  });
});

describe('Event structured data', () => {
  const published = { ...row(1), status: 'published' } as unknown as PublicMeetupDetail;
  const now = new Date('2026-11-27T10:00:00Z');

  it('describes a current, approved event with an offline attendance mode', () => {
    const ld = buildEventJsonLd(published, 'https://apnacircle.example/', now) as unknown as {
      '@type': string;
      eventStatus: string;
      eventAttendanceMode: string;
      url: string;
      remainingAttendeeCapacity: number;
      location: { address: { addressRegion: string; streetAddress?: string } };
      organizer: { '@type': string; name: string };
    };
    expect(ld['@type']).toBe('Event');
    expect(ld.eventStatus).toBe('https://schema.org/EventScheduled');
    expect(ld.eventAttendanceMode).toBe('https://schema.org/OfflineEventAttendanceMode');
    expect(ld.url).toBe('https://apnacircle.example/saharanpur/meetups/ride-1');
    expect(ld.location.address.addressRegion).toBe('Uttar Pradesh');
    expect(ld.remainingAttendeeCapacity).toBe(8);
    // A neighbourhood is not a street address, and the host's name is not published as structured data.
    expect(ld.location.address.streetAddress).toBeUndefined();
    expect(ld.organizer).toEqual(expect.objectContaining({ '@type': 'Organization', name: 'ApnaCircle' }));
    expect(JSON.stringify(ld.organizer)).not.toContain('Hari');
  });

  it('emits nothing for cancelled or past events', () => {
    expect(buildEventJsonLd({ ...published, status: 'cancelled' }, 'https://x', now)).toBeNull();
    expect(buildEventJsonLd(published, 'https://x', new Date('2027-01-01T00:00:00Z'))).toBeNull();
  });

  it('never leaks private fields into the structured data', () => {
    const text = JSON.stringify(buildEventJsonLd(published, 'https://x', now));
    expect(text).not.toMatch(/spot|attendees|user_id|email/i);
  });

  it('serialises so a hostile title cannot close the script tag', () => {
    const evil = { ...published, title: '</script><script>alert(1)</script>' } as PublicMeetupDetail;
    const out = serializeJsonLd(buildEventJsonLd(evil, 'https://x', now)!);
    expect(out).not.toContain('</script>');
    expect(out).not.toContain('<');
    expect(JSON.parse(out).name).toBe('</script><script>alert(1)</script>');
  });
});
