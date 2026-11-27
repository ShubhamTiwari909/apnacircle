import { describe, expect, it } from 'vitest';
import {
  decodeMeetupCursor,
  encodeMeetupCursor,
  isMeetupDateFilter,
  meetupDateRange,
  publicMeetupDetailSchema,
  publicMeetupSchema,
} from './meetups.js';

const base = {
  id: '3f6c1c52-2b64-4c0b-9a39-8d7d8a8f1a11',
  slug: 'sunday-ride-1a2b3c',
  city_slug: 'saharanpur',
  city_name: 'Saharanpur',
  category_slug: 'sports-and-fitness',
  category_name: 'Sports & Fitness',
  title: 'Sunday ride',
  description: 'A relaxed group ride.',
  venue_name: 'Company Garden',
  locality: 'Civil Lines',
  starts_at: '2026-11-29T04:30:00+00:00',
  ends_at: '2026-11-29T06:30:00+00:00',
  capacity: 10,
  attendee_count: 3,
  women_only: false,
  join_mode: 'auto',
  host_display_name: 'Hari',
};

describe('public meetup schemas', () => {
  it('accepts what the RPC returns and rejects malformed rows', () => {
    expect(publicMeetupSchema.safeParse(base).success).toBe(true);
    expect(publicMeetupSchema.safeParse({ ...base, capacity: 0 }).success).toBe(false);
    expect(publicMeetupSchema.safeParse({ ...base, starts_at: 'tomorrow' }).success).toBe(false);
    expect(publicMeetupDetailSchema.safeParse({ ...base, status: 'draft' }).success).toBe(false);
  });

  it('does not model private fields, so they can never be rendered from this shape', () => {
    expect(Object.keys(publicMeetupSchema.shape)).not.toContain('spot_note');
    expect(Object.keys(publicMeetupSchema.shape)).not.toContain('attendees');
  });
});

describe('meetupDateRange (IST)', () => {
  // Friday 27 Nov 2026, 15:30 IST
  const friday = new Date('2026-11-27T10:00:00Z');

  it('any time has no bounds', () => {
    expect(meetupDateRange('any', friday)).toEqual({ from: null, to: null });
  });

  it('today ends at the next IST midnight', () => {
    expect(meetupDateRange('today', friday)).toEqual({ from: friday.toISOString(), to: '2026-11-27T18:30:00.000Z' });
  });

  it('week covers the next 7 IST days', () => {
    expect(meetupDateRange('week', friday).to).toBe('2026-12-03T18:30:00.000Z');
  });

  it('weekend from a Friday is Saturday 00:00 to Monday 00:00 IST', () => {
    expect(meetupDateRange('weekend', friday)).toEqual({
      from: '2026-11-27T18:30:00.000Z',
      to: '2026-11-29T18:30:00.000Z',
    });
  });

  it('on Saturday and Sunday the current weekend is still this weekend', () => {
    const saturday = new Date('2026-11-28T05:00:00Z');
    const sunday = new Date('2026-11-29T05:00:00Z');
    expect(meetupDateRange('weekend', saturday)).toEqual({ from: saturday.toISOString(), to: '2026-11-29T18:30:00.000Z' });
    expect(meetupDateRange('weekend', sunday)).toEqual({ from: sunday.toISOString(), to: '2026-11-29T18:30:00.000Z' });
  });

  it('uses the IST day, not the UTC day (Friday 23:00 UTC is already Saturday in India)', () => {
    const lateUtc = new Date('2026-11-27T23:00:00Z');
    expect(meetupDateRange('today', lateUtc).to).toBe('2026-11-28T18:30:00.000Z');
  });

  it('recognises only known filters', () => {
    expect(isMeetupDateFilter('weekend')).toBe(true);
    expect(isMeetupDateFilter('yesterday')).toBe(false);
    expect(isMeetupDateFilter(null)).toBe(false);
  });
});

describe('meetup cursor', () => {
  it('round-trips and is URL safe', () => {
    const cursor = encodeMeetupCursor(base.starts_at, base.id);
    expect(cursor).toMatch(/^[A-Za-z0-9_-]+$/);
    expect(decodeMeetupCursor(cursor)).toEqual({ startsAt: base.starts_at, id: base.id });
  });

  it('rejects tampered, oversized or foreign cursors instead of passing them to the database', () => {
    expect(decodeMeetupCursor('not-base64!!')).toBeNull();
    expect(decodeMeetupCursor(btoa(JSON.stringify({ s: 'x', i: 'y' })))).toBeNull();
    expect(decodeMeetupCursor(btoa(JSON.stringify({ s: base.starts_at, i: "1' or '1'='1" })))).toBeNull();
    expect(decodeMeetupCursor('a'.repeat(500))).toBeNull();
    expect(decodeMeetupCursor(null)).toBeNull();
  });
});
