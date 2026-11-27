import { describe, expect, it } from 'vitest';
import { renderMessage } from './outbox.ts';

const SITE = 'https://apnacircle.example/';

describe('renderMessage', () => {
  it('renders a cancellation with title, time and the host reason, flagged priority', () => {
    const m = renderMessage(
      { type: 'meetup_cancelled', meetup_title: 'Sunday ride', reason: 'Heavy rain', starts_at: '2030-12-01T04:30:00Z', priority: true },
      SITE,
    )!;
    expect(m.subject).toBe('Cancelled: Sunday ride');
    expect(m.text).toContain('Reason from the host: Heavy rain');
    expect(m.text).toContain('Sun, 1 Dec');
    expect(m.text).toContain('10:00');
    expect(m.priority).toBe(true);
    expect(m.url).toBe('https://apnacircle.example/meetups');
  });

  it('is plain text with no member names, and strips control characters and length from host text', () => {
    const m = renderMessage({ type: 'meetup_cancelled', meetup_title: 'Ride\u0000\n<b>x</b>' + 'y'.repeat(500), reason: 'a\r\nb' }, SITE)!;
    expect(Array.from(m.subject).every((ch) => ch.charCodeAt(0) >= 32)).toBe(true);
    expect(m.subject.length).toBeLessThan(160);
    expect(m.text).toContain('Reason from the host: a b');
  });

  it('keeps member-to-member messages generic', () => {
    const m = renderMessage({ type: 'rsvp_requested', meetup_title: 'Ride', attendee_name: 'Priya Sharma', email: 'p@x.com' } as never, SITE)!;
    expect(m.text).not.toMatch(/Priya|p@x\.com/);
    expect(m.text).toContain('Someone has asked to join');
  });

  it('covers every type the database enqueues for email or push', () => {
    for (const type of ['rsvp_approved', 'rsvp_requested', 'rsvp_declined', 'meetup_cancelled', 'meetup_changed', 'meetup_reminder_24h', 'meetup_reminder_2h', 'host_decision', 'meetup_review', 'moderation_outcome']) {
      expect(renderMessage({ type, meetup_title: 'T' }, SITE), type).not.toBeNull();
    }
  });

  it('refuses unknown types instead of sending something half-formed', () => {
    expect(renderMessage({ type: 'new_message' }, SITE)).toBeNull();
    expect(renderMessage({}, SITE)).toBeNull();
  });

  it('words host decisions by outcome', () => {
    expect(renderMessage({ type: 'host_decision', decision: 'approve' }, SITE)!.subject).toContain('approved as a host');
    expect(renderMessage({ type: 'host_decision', decision: 'reject' }, SITE)!.subject).toContain('host application');
    expect(renderMessage({ type: 'meetup_review', decision: 'reject', meetup_title: 'T' }, SITE)!.subject).toContain('Needs changes');
  });
});
