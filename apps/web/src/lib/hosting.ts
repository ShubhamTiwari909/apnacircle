import { CATEGORIES, ACTIVE_CITIES } from '@apnacircle/types';
import { z } from 'zod';
import { authenticatedRequest } from './connection-abuse.js';
import type { PublicApiConfig } from './meetups.js';

const id = z.guid();
const iso = z.iso.datetime({ offset: true });
const field = (min: number, max: number) => z.string().trim().min(min).max(max);
const optional = (max: number) => z.string().trim().max(max);
const city = z.string().refine((value) => ACTIVE_CITIES.some(({ slug }) => slug === value));
const category = z.string().refine((value) => CATEGORIES.some(({ slug, kind }) => slug === value && kind === 'activity'));
const statuses = z.enum(['draft', 'pending_approval', 'published', 'rejected', 'cancelled', 'completed']);
const hostStatus = z.enum(['pending', 'approved', 'rejected', 'suspended']);

const setup = z.object({
  state: z.enum(['new', 'complete', 'unavailable']),
  invited: z.boolean(),
  age_locked: z.boolean(),
  interests: z.array(z.object({ id, name: z.string() })),
});

export const onboardingForm = z.object({
  displayName: field(2, 50),
  city,
  dob: z.iso.date(),
  invite: optional(128),
  interests: z.array(id).max(10),
  terms: z.literal(true),
  guidelines: z.literal(true),
  discovery: z.boolean(),
  cityVisible: z.boolean(),
  emailNotifications: z.boolean(),
  analytics: z.boolean(),
  turnstile: field(1, 2048),
});

export const hostForm = z.object({
  organisation: optional(120),
  about: field(30, 2000),
  social: optional(250).refine((value) => !value || /^https:\/\/[^\s]+$/.test(value)),
  reference: optional(500),
  agreement: field(1, 100),
});

const istDateTime = z.string().regex(/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}$/).refine((value) => {
  const day = value.slice(0, 10);
  return z.iso.date().safeParse(day).success && Number.isFinite(Date.parse(value + ':00+05:30'));
}).transform((value) => value + ':00+05:30');

export const meetupForm = z.object({
  city, category, title: field(5, 120), description: field(20, 4000),
  venue: field(3, 120), locality: field(2, 80), spot: optional(300),
  starts: istDateTime, ends: z.union([istDateTime, z.literal('').transform(() => null)]),
  capacity: z.coerce.number().int().min(2).max(50),
  womenOnly: z.boolean(), joinMode: z.enum(['auto', 'approval']), publicVenue: z.literal(true),
}).refine(({ starts, ends }) => ends === null || Date.parse(ends) > Date.parse(starts));

const workspace = z.object({
  host_status: hostStatus.nullable(),
  agreement: z.string(),
  established: z.boolean(),
  staff: z.boolean(),
  admin: z.boolean(),
  meetups: z.array(z.object({ meetup_id: id, title: z.string(), city_slug: z.string(), slug: z.string(), starts_at: iso, status: statuses })),
});

const reviewQueue = z.object({
  host_applications: z.array(z.object({
    user_id: id, display_name: z.string(), organisation_name: z.string().nullable(), about: z.string(),
    social_profile_url: z.string().nullable(), local_reference: z.string().nullable(), applied_at: iso,
  })),
  meetups: z.array(z.object({
    meetup_id: id, title: z.string(), description: z.string(), host_name: z.string(),
    venue_name: z.string(), locality: z.string(), spot_note: z.string().nullable(), starts_at: iso, ends_at: iso.nullable(),
    capacity: z.number().int(), women_only: z.boolean(),
  })),
});

export const hostReviewForm = z.object({
  type: z.enum(['host', 'meetup']), id, decision: z.enum(['approve', 'reject']),
  method: z.enum(['', 'video_call', 'phone_call', 'in_person']), note: field(10, 1000),
});

function rpc<T>(config: PublicApiConfig, token: string, name: string, schema: z.ZodType<T>, args: Record<string, unknown> = {}) {
  return authenticatedRequest<T>(config, token, '/rest/v1/rpc/' + name, async (response) => {
    const body = await response.text();
    return schema.parse(body ? JSON.parse(body) : null);
  }, args);
}

const empty = z.null();
const setupOutcome = z.enum(['complete', 'age_locked', 'invite_required']);
const createdMeetup = z.object({ id, status: statuses });

export const getOnboarding = (config: PublicApiConfig, token: string) => rpc(config, token, 'get_member_onboarding', setup);

export function completeOnboarding(config: PublicApiConfig, token: string, key: string, input: z.output<typeof onboardingForm>, notice: string) {
  return rpc(config, token, 'complete_member_onboarding', setupOutcome, {
    p_write_key: key, p_name: input.displayName, p_city_slug: input.city, p_dob: input.dob,
    p_invite: input.invite || null, p_interests: input.interests, p_terms: input.terms, p_guidelines: input.guidelines,
    p_discovery: input.discovery, p_city_visible: input.cityVisible, p_email_notifications: input.emailNotifications,
    p_analytics: input.analytics, p_notice_version: notice,
  });
}

export const getHostWorkspace = (config: PublicApiConfig, token: string) => rpc(config, token, 'get_host_workspace', workspace);

export function applyToHost(config: PublicApiConfig, token: string, input: z.output<typeof hostForm>) {
  return rpc(config, token, 'apply_as_host', empty, {
    p_organisation: input.organisation || null, p_about: input.about, p_social_url: input.social || null,
    p_reference: input.reference || null, p_agreement_version: input.agreement,
  });
}

function meetupFields(input: z.output<typeof meetupForm>) {
  return { p_category_slug: input.category, p_title: input.title, p_description: input.description,
    p_venue_name: input.venue, p_locality: input.locality, p_spot_note: input.spot || null,
    p_starts_at: input.starts, p_ends_at: input.ends, p_capacity: input.capacity, p_women_only: input.womenOnly,
    p_join_mode: input.joinMode, p_venue_confirmed_public: input.publicVenue,
  };
}

export function createMeetup(config: PublicApiConfig, token: string, input: z.output<typeof meetupForm>) {
  return rpc(config, token, 'create_and_submit_meetup', createdMeetup, { p_city_slug: input.city, ...meetupFields(input) });
}

const hostMeetupEditor = z.object({
  city: z.string(), category: z.string(), title: z.string(), description: z.string(),
  venue: z.string(), locality: z.string(), spot: z.string(), starts: iso, ends: iso.nullable(),
  capacity: z.number().int(), joinMode: z.enum(['auto', 'approval']), womenOnly: z.boolean(),
  publicVenue: z.boolean(), editable: z.boolean(), updatedAt: iso,
});

export function hostMeetupEditorPath(id: string) {
  return '/me/host/meetups/' + id;
}

export function getHostMeetupEditor(config: PublicApiConfig, token: string, id: string) {
  return rpc(config, token, 'get_host_meetup_editor', hostMeetupEditor, { p_meetup_id: id });
}

export function saveHostMeetup(config: PublicApiConfig, token: string, id: string, expected: string, input: z.output<typeof meetupForm>) {
  return rpc(config, token, 'save_host_meetup', statuses, {
    p_meetup_id: id, p_expected_at: expected, ...meetupFields(input),
  });
}

export const getHostReview = (config: PublicApiConfig, token: string) => rpc(config, token, 'get_host_review_queue', reviewQueue);

export function reviewHostItem(config: PublicApiConfig, token: string, data: z.output<typeof hostReviewForm>) {
  return rpc(config, token, 'decide_host_review', empty, {
    p_type: data.type, p_id: data.id, p_decision: data.decision, p_method: data.method || null, p_note: data.note,
  });
}

export async function issueMemberInvite(config: PublicApiConfig, token: string) {
  const hex = (bytes: Uint8Array) => Array.from(bytes, (value) => value.toString(16).padStart(2, '0')).join('');
  const code = hex(crypto.getRandomValues(new Uint8Array(16)));
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(code));
  const result = await rpc(config, token, 'issue_member_invite', empty, { p_hash: hex(new Uint8Array(digest)) });
  return result.ok ? { ok: true as const, code } : result;
}
