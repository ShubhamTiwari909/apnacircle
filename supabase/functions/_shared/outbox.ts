// Message rendering for the outbox worker. Pure and dependency-free so it can be unit tested.
//
// Rules from plan 3.9: plain text only (no HTML to inject into), no other member's name, photo,
// message or contact handle, and generic wording for anything member-to-member. The only
// free text that appears is the host's own meetup title and cancellation reason, length-limited
// and stripped of control characters.

export interface OutboxPayload {
  type?: unknown;
  priority?: unknown;
  meetup_title?: unknown;
  reason?: unknown;
  decision?: unknown;
  starts_at?: unknown;
  grace_ends_at?: unknown;
}

export interface RenderedMessage {
  subject: string;
  text: string;
  pushTitle: string;
  pushBody: string;
  url: string;
  priority: boolean;
}

// Zero-width characters and bidirectional controls can hide or reorder text.
const INVISIBLE = /[\u200B-\u200F\u202A-\u202E\u2060\u2066-\u2069\uFEFF]/g;
// Links in host-typed text would appear inside an email that carries the ApnaCircle name.
const LINKS = /(?:https?:\/\/|www\.)\S*/gi;

function clean(value: unknown, max: number): string {
  if (typeof value !== 'string') return '';
  const spaced = Array.from(value, (ch) => {
    const code = ch.codePointAt(0) ?? 0;
    return code < 32 || (code >= 127 && code <= 159) ? ' ' : ch;
  }).join('');
  const text = spaced.replace(INVISIBLE, '').replace(LINKS, '').replace(/\s+/g, ' ').trim();
  // Truncate by code point so an emoji is never cut in half.
  return Array.from(text).slice(0, max).join('');
}

const whenFormat = new Intl.DateTimeFormat('en-IN', {
  weekday: 'short',
  day: 'numeric',
  month: 'short',
  hour: 'numeric',
  minute: '2-digit',
  timeZone: 'Asia/Kolkata',
});

function when(value: unknown): string {
  if (typeof value !== 'string') return '';
  const date = new Date(value);
  return Number.isNaN(date.getTime()) ? '' : `${whenFormat.format(date)} IST`;
}

export function renderMessage(payload: OutboxPayload, siteUrl: string): RenderedMessage | null {
  const type = clean(payload.type, 40);
  const title = clean(payload.meetup_title, 120) || 'your meetup';
  const at = when(payload.starts_at);
  const reason = clean(payload.reason, 300);
  const decision = clean(payload.decision, 20);
  const priority = payload.priority === true;
  const site = siteUrl.replace(/\/+$/, '');
  const url = `${site}/meetups`;

  const make = (subject: string, lines: string[], pushBody: string): RenderedMessage => ({
    subject,
    text: [...lines, '', `Open ApnaCircle: ${url}`, '', '- ApnaCircle'].join('\n'),
    pushTitle: subject,
    pushBody,
    url,
    priority,
  });

  switch (type) {
    case 'rsvp_approved':
      return make(
        `You're going: ${title}`,
        [`Your place at "${title}" is confirmed${at ? ` for ${at}` : ''}.`, 'The exact meeting spot is in the meetup details in ApnaCircle.'],
        'Your place is confirmed.',
      );
    case 'rsvp_requested':
      return make(`New request to join ${title}`, ['Someone has asked to join your meetup. Review the request in ApnaCircle.'], 'You have a new request.');
    case 'rsvp_declined':
      return make(`Update on ${title}`, ['The host is not able to include you in this meetup.'], 'The host could not include you.');
    case 'meetup_cancelled':
      return make(
        `Cancelled: ${title}`,
        [`The host has cancelled "${title}"${at ? ` (${at})` : ''}.`, ...(reason ? [`Reason from the host: ${reason}`] : []), 'You do not need to do anything else.'],
        `Cancelled: ${title}`,
      );
    case 'meetup_changed':
      return make(`Changed: ${title}`, [`The time or place of "${title}" has changed. Please check the new details before you set off.`], 'Please check the new details.');
    case 'meetup_on_hold':
      return make(
        `On hold: ${title}`,
        [`"${title}" is on hold for now${at ? ` (it was planned for ${at})` : ''}. Please check ApnaCircle before you set off.`],
        `On hold: ${title}`,
      );
    case 'meetup_reminder_24h':
      return make(`Tomorrow: ${title}`, [`A reminder that "${title}" starts ${at || 'tomorrow'}.`], at ? `Starts ${at}` : 'Starts tomorrow');
    case 'meetup_reminder_2h':
      return make(`Starting soon: ${title}`, [`"${title}" starts in about two hours${at ? ` (${at})` : ''}.`], 'Starts in about two hours');
    case 'host_decision':
      return decision === 'approve'
        ? make("You're approved as a host", ['Your host application has been approved. You can now create meetups in ApnaCircle.'], 'You can now create meetups.')
        : decision === 'suspend'
          ? make('Your host access has been paused', ['Your host access has been paused. Please open ApnaCircle for details.'], 'Your host access has been paused.')
          : make('About your host application', ['We have an update on your host application. Please open ApnaCircle for details.'], 'Update on your host application.');
    case 'meetup_review':
      return decision === 'approve'
        ? make(`Approved: ${title}`, [`Your meetup "${title}" is approved and now public.`], 'Your meetup is now public.')
        : make(`Needs changes: ${title}`, [`An admin has asked for changes to "${title}" before it can go live. Open ApnaCircle to read their note.`], 'Changes requested.');
    case 'moderation_outcome':
      return make('Update on your report', ['There is an update on a report you made. Please open ApnaCircle for details.'], 'There is an update on your report.');
    case 'moderation_action':
      // Deliberately generic: the moderator's reason is not copied into email.
      return make('An update about your account', ['A moderation decision has been made about your account. Please open ApnaCircle for details.'], 'There is an update about your account.');
    case 'account_deletion_requested': {
      const graceEnds = when(payload.grace_ends_at);
      return make(
        'We received your account deletion request',
        [
          `We received a request to delete your ApnaCircle account${graceEnds ? `. It will be deleted after ${graceEnds}` : ''}.`,
          'If you did not make this request, please contact ApnaCircle support straight away.',
        ],
        'We received your account deletion request.',
      );
    }
    default:
      return null;
  }
}
