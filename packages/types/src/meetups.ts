import { z } from 'zod';

// Shapes returned by the public meetup RPCs (supabase migration 007). They deliberately contain no
// spot note, no attendee names and no host identifiers: those are member-only (plan 3.8).

const isoTimestamp = z.string().datetime({ offset: true });

export const publicMeetupSchema = z.object({
  id: z.string().uuid(),
  slug: z.string().min(1),
  city_slug: z.string().min(1),
  city_name: z.string().min(1),
  category_slug: z.string().min(1),
  category_name: z.string().min(1),
  title: z.string().min(1),
  description: z.string(),
  venue_name: z.string().min(1),
  locality: z.string().min(1),
  starts_at: isoTimestamp,
  ends_at: isoTimestamp.nullable(),
  capacity: z.number().int().positive(),
  attendee_count: z.number().int().nonnegative(),
  women_only: z.boolean(),
  join_mode: z.enum(['auto', 'approval']),
  host_display_name: z.string().min(1),
});

export const publicMeetupDetailSchema = publicMeetupSchema.extend({
  status: z.enum(['published', 'cancelled']),
});

export type PublicMeetup = z.infer<typeof publicMeetupSchema>;
export type PublicMeetupDetail = z.infer<typeof publicMeetupDetailSchema>;

// ---------------------------------------------------------------------------------------------
// Date filters (all in IST, which has no daylight saving: a fixed +05:30 offset)
// ---------------------------------------------------------------------------------------------

export const MEETUP_DATE_FILTERS = ['any', 'today', 'weekend', 'week'] as const;
export type MeetupDateFilter = (typeof MEETUP_DATE_FILTERS)[number];

const IST_OFFSET_MS = 330 * 60 * 1000;
const DAY_MS = 24 * 60 * 60 * 1000;

export function isMeetupDateFilter(value: string | null | undefined): value is MeetupDateFilter {
  return MEETUP_DATE_FILTERS.includes(value as MeetupDateFilter);
}

/** Start of the IST calendar day containing `now`, as a UTC instant. */
function startOfIstDay(now: Date): Date {
  const shifted = new Date(now.getTime() + IST_OFFSET_MS);
  return new Date(Date.UTC(shifted.getUTCFullYear(), shifted.getUTCMonth(), shifted.getUTCDate()) - IST_OFFSET_MS);
}

export interface DateRange {
  from: string | null;
  to: string | null;
}

export function meetupDateRange(filter: MeetupDateFilter, now: Date = new Date()): DateRange {
  const today = startOfIstDay(now);
  switch (filter) {
    case 'today':
      return { from: now.toISOString(), to: new Date(today.getTime() + DAY_MS).toISOString() };
    case 'week':
      return { from: now.toISOString(), to: new Date(today.getTime() + 7 * DAY_MS).toISOString() };
    case 'weekend': {
      const istDow = new Date(now.getTime() + IST_OFFSET_MS).getUTCDay(); // 0 Sun .. 6 Sat
      // On Saturday/Sunday the current weekend is still "this weekend".
      const daysToSaturday = istDow === 6 ? 0 : istDow === 0 ? -1 : 6 - istDow;
      const saturday = new Date(today.getTime() + daysToSaturday * DAY_MS);
      const from = saturday.getTime() > now.getTime() ? saturday : now;
      return { from: from.toISOString(), to: new Date(saturday.getTime() + 2 * DAY_MS).toISOString() };
    }
    default:
      return { from: null, to: null };
  }
}

// ---------------------------------------------------------------------------------------------
// Keyset pagination cursor: (starts_at, id). Opaque to users, validated on the way back in.
// ---------------------------------------------------------------------------------------------

const cursorSchema = z.object({ s: isoTimestamp, i: z.string().uuid() });

export function encodeMeetupCursor(startsAt: string, id: string): string {
  const json = JSON.stringify({ s: startsAt, i: id });
  return btoa(json).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

export function decodeMeetupCursor(cursor: string | null | undefined): { startsAt: string; id: string } | null {
  if (!cursor || cursor.length > 200) return null;
  try {
    const padded = cursor.replace(/-/g, '+').replace(/_/g, '/') + '='.repeat((4 - (cursor.length % 4)) % 4);
    const parsed = cursorSchema.safeParse(JSON.parse(atob(padded)));
    return parsed.success ? { startsAt: parsed.data.s, id: parsed.data.i } : null;
  } catch {
    return null;
  }
}
