import { createHash, randomUUID } from 'node:crypto';
import { URL } from 'node:url';

export const origin = 'http://127.0.0.1:4173';
const googleFixtureOrigin = 'http://localhost:4173';
const anonKey = 'fixture-anon';
const memberSession = 'fixture.member.session';
const writeKey = 'fixture-feedback-writer';
const challengeSecret = 'fixture-turnstile';
const projectKey = 'fixture-posthog';
const { Response } = globalThis;
const codes = new Map();
const observations = { feedback: [], analytics: [] };
const reviewFixture = {
  id: '3027af97-3e97-4654-9b1b-307a50e645f8',
  category: 'content_correction',
  subject: 'Correct the park opening hours',
  status: 'new',
  created_at: new Date().toISOString(),
  message: 'The park now opens earlier on weekdays.',
  contact_email: null,
  reviews: [],
};

export function installProviders() {
  Object.assign(process.env, {
    PUBLIC_SUPABASE_URL: origin,
    PUBLIC_SUPABASE_ANON_KEY: anonKey,
    FEEDBACK_WRITE_KEY: writeKey,
    TURNSTILE_SECRET_KEY: challengeSecret,
    POSTHOG_PROJECT_KEY: projectKey,
  });
  const requestLive = globalThis.fetch;
  globalThis.fetch = async (target, options) => {
    if (target === 'https://challenges.cloudflare.com/turnstile/v0/siteverify') {
      const form = new URL(target);
      form.search = options.body;
      return Response.json({
        success: form.searchParams.get('secret') === challengeSecret &&
          form.searchParams.get('response') === 'fixture-verified',
      });
    }
    if (target === 'https://eu.i.posthog.com/capture/') {
      const { api_key: key, ...payload } = JSON.parse(options.body);
      if (key !== projectKey) return new Response(null, { status: 401 });
      observations.analytics.push(payload);
      return new Response(null, { status: 204 });
    }
    if (new URL(target).origin === origin) return requestLive(target, options);
    throw new Error('Unexpected external request in browser test');
  };
}

const meetup = {
  id: '7bbe3867-6ede-4b04-ba6f-44a5bf1ac204',
  slug: 'test-city-walk',
  city_slug: 'saharanpur',
  city_name: 'Saharanpur',
  category_slug: 'nature-and-parks',
  category_name: 'Nature and parks',
  title: 'Test city walk',
  description: 'A public meetup fixture.',
  venue_name: 'Company Garden',
  locality: 'Saharanpur',
  starts_at: new Date(Date.now() + 86_400_000).toISOString(),
  ends_at: null,
  capacity: 12,
  attendee_count: 2,
  women_only: false,
  join_mode: 'auto',
  host_display_name: 'Test host',
  status: 'published',
};
const publicTeaser = {
  directoryOpen: false,
  teaser: { memberCountFloor: 0, popularInterests: [], upcomingMeetups: [] },
};

export async function providerResponse(request) {
  const { pathname, searchParams } = new URL(request.url);
  const authorization = request.headers.get('authorization');
  const isMember = authorization === `Bearer ${memberSession}`;
  const isStaff = authorization === 'Bearer fixture.staff.session';

  switch (pathname) {
    case '/__test/observations':
      if (request.method === 'POST') {
        observations.feedback.length = 0;
        observations.analytics.length = 0;
        codes.clear();
        reviewFixture.status = 'new';
        reviewFixture.reviews = [];
      }
      return Response.json(observations);
    case '/auth/v1/authorize': {
      const challenge = searchParams.get('code_challenge');
      if (searchParams.get('provider') !== 'google' || searchParams.get('redirect_to') !== origin + '/me/profile/auth' ||
          searchParams.get('code_challenge_method') !== 's256' || !/^[\w-]{43}$/.test(challenge ?? '')) {
        return new Response('Invalid OAuth request', { status: 400 });
      }
      const code = randomUUID();
      codes.set(code, challenge);
      return Response.redirect(googleFixtureOrigin + '/__test/google?code=' + code);
    }
    case '/__test/google': {
      const code = searchParams.get('code');
      if (!codes.has(code)) return new Response(null, { status: 404 });
      const callback = new URL('/me/profile/auth', origin);
      callback.searchParams.set('code', code);
      return new Response(`<!doctype html><title>Google test fixture</title><h1>Choose an account</h1>
        <a href="${callback.href}">Continue as test member</a>
        <a href="${origin}/me/profile/auth?error=access_denied">Cancel sign-in</a>`, {
        headers: { 'Content-Type': 'text/html' },
      });
    }
    case '/auth/v1/token': {
      const { auth_code: code, code_verifier: verifier } = await request.json();
      const expected = codes.get(code);
      if (searchParams.get('grant_type') !== 'pkce' || request.headers.get('apikey') !== anonKey ||
          !expected || typeof verifier !== 'string' || createHash('sha256').update(verifier).digest('base64url') !== expected) {
        return new Response(null, { status: 400 });
      }
      codes.delete(code);
      return Response.json({ access_token: memberSession, expires_in: 3600 });
    }
    case '/auth/v1/user':
      return isMember ? Response.json({ id: meetup.id }) : new Response(null, { status: 401 });
    case '/rest/v1/rpc/get_my_profile_editor':
      return new Response(null, { status: isMember ? 403 : 401 });
    case '/rest/v1/rpc/get_city_people_page':
      return isMember || authorization === `Bearer ${anonKey}`
        ? Response.json(publicTeaser) : new Response(null, { status: 401 });
    case '/rest/v1/rpc/get_public_meetup':
      return Response.json((await request.json()).p_slug === meetup.slug ? [meetup] : []);
    case '/rest/v1/rpc/list_site_feedback': {
      if (!isStaff) return new Response(null, { status: 403 });
      const { p_status: status } = await request.json();
      const { id, subject, category, status: current, created_at } = reviewFixture;
      return Response.json({ items: !status || status === current ? [{ id, subject, category, status: current, created_at }] : [], nextCursor: null });
    }
    case '/rest/v1/rpc/get_site_feedback': {
      if (!isStaff) return new Response(null, { status: 403 });
      const { p_id: id } = await request.json();
      return id === reviewFixture.id ? Response.json(reviewFixture) : new Response(null, { status: 404 });
    }
    case '/rest/v1/rpc/review_site_feedback': {
      if (!isStaff) return new Response(null, { status: 403 });
      const { p_id: id, p_expected_status: expected, p_decision: decision, p_note: reason } = await request.json();
      if (id !== reviewFixture.id) return new Response(null, { status: 404 });
      if (expected !== reviewFixture.status) return new Response(null, { status: 409 });
      reviewFixture.status = { start: 'triaged', approve: 'resolved', dismiss: 'closed' }[decision];
      reviewFixture.reviews.unshift({
        id: randomUUID(), action: decision, reason, reviewer_name: 'Test moderator', created_at: new Date().toISOString(),
      });
      return new Response(null, { status: 204 });
    }
    case '/rest/v1/rpc/submit_site_feedback': {
      const { p_write_key: key, ...fields } = await request.json();
      if (key !== writeKey) return new Response(null, { status: 403 });
      const id = randomUUID();
      observations.feedback.push({ id, ...fields });
      return Response.json(id);
    }
  }
  return null;
}
