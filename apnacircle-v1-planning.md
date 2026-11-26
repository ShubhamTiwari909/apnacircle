# ApnaCircle — Version 1.1 Product, Safety & Engineering Plan

> [!INFO] **Working title only:** ApnaCircle. "Apna" is an established Indian brand name (apna.co), so complete trademark and domain clearance before buying a domain or publishing anything.
> **Document status:** Implementation blueprint · **Version:** 1.1 (supersedes 1.0; the original is kept as `apnacircle-v1.0-backup.md`) · **Date:** 26 November 2026
> **Primary objective:** Validate a safe, useful, city-based social discovery and meetup product, with trust and safety built in before any social feature ships.

---

## 0. Executive summary and what changed in v1.1

Build a mobile-first platform that helps adults in a city discover local places, group activities and, once the community is large enough, each other. The product should encourage real-world social interaction rather than become an anonymous chat or swipe-dating app.

**Version 1.1 principles**

1. Start with Saharanpur; architect for multiple cities from day one.
2. **Meetups first.** Group, public-venue meetups are the wedge: lower risk, easier to seed with local hosts, and they create the trust that one-to-one connections need. The people directory and connection requests unlock later, behind numeric gates.
3. Public pages are city, category, place, article and meetup pages. **Member profiles and photos are visible only to signed-in members.** No anonymous browsing of people.
4. **Trust and safety ships before social features.** Report, block, moderation queue, audit log, notifications and account deletion exist before any member can see or contact another member.
5. No in-app direct messaging in V1. After a mutual connection, users may explicitly share an Instagram or WhatsApp handle for that connection only.
6. Collect only data with a stated V1 purpose. **No phone number is collected in V1.**
7. Gemini is used only through an owner-triggered pipeline that produces draft pull requests from verified fact packs. Normal visitors never trigger an AI call, and nothing is published without human review.
8. Free tiers are for development, alpha and closed beta. **Public launch requires a small, approved paid baseline** (backups, no pausing, sender domain). Never hold irreplaceable user data on a service without tested backups.
9. English only at launch, built so Hindi can be added later without rework.
10. Privacy, consent, moderation and abuse prevention are core product features and have named owners and service levels.

**V1 success is not "lots of pages" or registrations.** It is evidence that real people attend meetups, return, accept requests they actually want, and feel safe.

### 0.1 Review findings and how v1.1 resolves them

| # | Finding in v1.0 | Resolution in v1.1 | Section |
|---|---|---|---|
| 1 | People directory and photos were public and anonymous, yet not indexable (all risk, no SEO benefit) | Members-only directory, profiles and photos; logged-out teaser shows only rounded counts; noindex plus anti-scraping controls | 3.5, 9 |
| 2 | RLS cannot hide columns; phone sat beside public fields | Public/private table split, unexposed private schema, column privileges, security-invoker views, automated exposure tests | 8.3, 8.4 |
| 3 | No email or push meant requests and cancellations went unseen | In-app plus email plus Web Push, outbox with retries, preferences, meetup reminders and priority cancellation alerts | 3.9 |
| 4 | 100 requests/day was spam-grade; declined users could be re-requested; no women-safety design | Trust tiers (3/10/20 per day), pending cap, cooldowns, silent decline, auto-restriction, recipient controls, women-safety measures | 4.1 to 4.3 |
| 5 | Phone collected with no purpose (liability, minimisation) | Phone removed from V1; revisit only with an approved OTP provider and a stated purpose | 3.6 |
| 6 | Safety features arrived after the risky features; Turnstile only in Phase 8 | New phase order: Trust and Safety core is Phase 3, before meetups, directory or requests; invite-only until then; Turnstile from Phase 1 | 11 |
| 7 | Storage and egress arithmetic did not work on free tier | Photo variants and budgets, photo cap, signed-URL strategy, Pro tier at public launch, optional R2 later | 3.7, 7.4 |
| 8 | Astro has no ISR, so "targeted revalidation" was impossible | Static content rebuilt on merge, SSR with short edge cache for dynamic pages, explicit CPU contingency | 7.5 |
| 9 | Payload on Render Free was fragile (RAM, sleep, ephemeral disk, pooling) | Git-based content with preview deploys and a draft-PR content studio; Payload deferred with a documented adoption trigger and Appendix A | 7.6, App. A |
| 10 | Cities and categories duplicated across Payload and the app DB | One source file seeded into the DB; build fails on unknown slugs | 8.1 |
| 11 | Redundant Worker to Edge Function hop; Gemini endpoint location unspecified; two admin identities | Astro server endpoints plus RPC; Edge Functions only for jobs; Gemini runs in a GitHub Action; one identity system with MFA | 7.3, 7.6 |
| 12 | Free tier plus real users plus privacy promises was inconsistent | Release stages with a Launch Baseline; nightly encrypted backups and restore drills from Phase 2 | 2, 9.4 |
| 13 | Riskiest hypothesis built last; no supply plan; no numbers | Meetups-first order, host seeding programme, invite codes, numeric stage and expansion gates | 2, 11, 12 |
| 14 | English-only for a Hindi-speaking audience | **Owner decision D5: English only at launch.** Build stays language-ready (message catalogues, locale field, no hard-coded strings); risk accepted and reviewed after Stage B; Hindi has a defined post-launch gate | 3.10 |
| 15 | Gemini would invent small-city facts; verification cost hidden | Fact packs, claim tagging, blocking CI gate on unverified claims, originality and rate caps | 7.6 |
| 16 | DPDP covered by one checklist line | Compliance workstream: notices, consent log, retention schedule, rights flows, breach runbook, processors, age gate, analytics consent | 5 |
| 17 | IT Rules 2021 intermediary duties not mentioned | Grievance officer, takedown timelines, retention and lawful-order process (to be confirmed by counsel) | 5.2 |
| 18 | Day trips and trekking carried liability; no host or attendee terms | V1 excludes trekking, overnight and outstation; host agreement, attendee acknowledgement, host vetting, venue rules | 3.8 |
| 19 | "Moderation is staffed" without owner, SLA or ban-evasion controls | Named owner and backup, SLA table, sanction ladder, appeals, evidence snapshots, hashed ban identifiers, photo-hash blocklist | 4.4, 4.5 |
| + | Smaller items: schema gaps, UTC day reset, brand clash, doc drift, Pages vs Workers, SMTP limits, photo-limit enforcement | All addressed in the relevant sections; the Markdown is now the single source and the HTML is generated from it | various |

### 0.2 Owner decisions (all approved)

These changed scope, cost or stack relative to v1.0. The owner approved D1 to D4 and D6 to D8 as written and chose English only for D5. Approval does not complete the follow-up work: D2 needs budget set and recorded in an ADR at the Stage C gate, D4 needs counsel to confirm the age-gate approach, D6 needs the people named before Stage B, and D7 needs the reviewer and budget chosen before Stage C.

| ID | Decision | Default in this plan | Why it needs you | Status |
|---|---|---|---|---|
| D1 | Content system | Git-based content (Astro content collections) with a Gemini GitHub Action that opens draft PRs; Payload deferred | Replaces the stack you chose; the owner edits through pull requests | Approved by owner, 26 Nov 2026 |
| D2 | Paid launch baseline | Supabase Pro (about US$25/month), custom domain, email sender domain; optional Workers Paid (about US$5/month) | Conflicts with the ₹0 target; free tier only for alpha and closed beta | Approved by owner, 26 Nov 2026 |
| D3 | Photo cap | 6 additional photos in beta, raise to 10 after Pro and an egress review | Product change from 10 | Approved by owner, 26 Nov 2026 |
| D4 | Age gate | Date of birth collected privately for an 18+ gate; no age filter in V1 | Data and legal decision | Approved by owner, 26 Nov 2026 |
| D5 | Languages | **Decided: English only at launch**, language-ready build, Hindi after Stage B | Accepted risk: Hindi-first users may sign up less; review after Stage B | Approved by owner, 26 Nov 2026 (changed to English only) |
| D6 | Trust and safety staffing | Named lead plus a trained backup before Stage B | Needs people, not code | Approved by owner, 26 Nov 2026 |
| D7 | Security review | Independent review or penetration test before public launch | Needs budget | Approved by owner, 26 Nov 2026 |
| D8 | Meetup scope | No trekking, overnight, outstation or organised-transport events in V1 | Removes categories from v1.0 | Approved by owner, 26 Nov 2026 |

---

## 1. Product vision, positioning and rollout

**Working positioning:** "Find your people. Explore your city."

The product combines:
- Group outings and meetups (the core loop).
- Local discovery guides and recommendations.
- Interest-based communities.
- Optional one-to-one connection requests, unlocked once the community is large enough.

Dating is not the primary identity. The default experience supports friendship, hobbies, group activities and professional communities.

### Initial geography

Design the data model for multiple cities immediately, but activate cities in stages:

1. Saharanpur: launch and learn.
2. Roorkee and Muzaffarnagar, once the expansion gates in section 12 are met.
3. Haridwar and Dehradun.
4. Meerut.
5. Further cities only with a local host and community acquisition plan.

A user has a primary city and may browse other active cities. Every meetup belongs to one city.

### V1 non-goals

- No in-app real-time chat or WebSocket messaging; no anonymous direct messages.
- No phone number collection; no public email addresses.
- No anonymous (logged-out) browsing of member profiles or photos.
- No live location sharing or home-address discovery.
- No swipe-first dating mechanic.
- No trekking, overnight, outstation or organised-transport events.
- No microservices, Kubernetes, Kafka, Elasticsearch or mandatory Redis.
- No automated publishing of AI content.
- No paid ads, subscriptions or monetisation until product signals exist.

---

## 2. Release stages and launch policy

Free tiers are acceptable for development and closed testing. They are not acceptable for a public product that holds personal data and promises privacy.

| Stage | Audience | Infrastructure | Entry and exit gates |
|---|---|---|---|
| Dev | Team | Local Supabase CLI, free accounts | Phase 0 to 2 complete |
| A: Alpha | Invite-only, up to 50 people, about 4 weeks | Free tier (staging and prod are the 2 free Supabase projects), Mumbai region | Phase 3 complete (trust and safety live); no open severity 1 or 2 security defect; at least 5 hosts recruited |
| B: Closed beta | Invite codes, up to 300 members, about 8 weeks | Free tier only if nightly backup and restore drill pass; otherwise Launch Baseline now | Stage A numeric gates (section 12); moderation lead plus trained backup named |
| C: Public Saharanpur launch | Public sign-up | **Launch Baseline** (below) | Stage B numeric gates; legal sign-off; independent security review; all section 15 checklist items |

### Launch Baseline (approval required, D2)

- Supabase Pro or equivalent: daily backups, no inactivity pausing, higher quotas (verify current terms and prices).
- Custom domain and a verified email sender domain (needed for reliable email deliverability and email trust).
- Optional Cloudflare Workers Paid if the free CPU or request limit is hit.
- Monthly spend alert and a written cap, recorded in an ADR.

Before enabling any paid service: identify the limit that forces it, estimate usage, compare options, obtain explicit owner approval, set a spend cap and alert, and record the decision.

---

## 3. Version 1 feature scope

### 3.1 Routes and access model

**Public (indexable where useful, no login):**

```text
/
/cities
/saharanpur
/saharanpur/meetups
/saharanpur/places
/saharanpur/places-to-visit
/saharanpur/cafes-and-restaurants
/saharanpur/photography-spots
/saharanpur/weekend-activities
/saharanpur/blog/<article-slug>
/meetups  /meetups/<slug>
/places
/about  /safety  /community-guidelines  /host-guidelines
/privacy  /terms  /cookies  /grievance  /legal/requests  /feedback
/.well-known/security.txt
```

**Members only (signed in, onboarded, noindex, never cached publicly):**

```text
/people  /saharanpur/people  /u/<opaque-id>
/me/*  /requests  /notifications  /settings
```

Logged-out visitors who open a members-only route see a sign-in prompt and, for `/people`, a teaser: rounded member count for the city, popular interests and upcoming meetups. No names, photos or bios are rendered or present in the HTML or API response.

Equivalent city routes exist for other cities when they are activated. Policy pages are published in English (Hindi follows under the gate in 3.10).

### 3.2 City and category pages

Each active city page includes a unique introduction, popular categories, curated verified places, upcoming public meetups, latest guides, local FAQs and clear calls to action (explore places, join a meetup). The People entry shows "Coming soon: meet people through meetups" until the unlock rule in 3.5 is met.

Category taxonomy (versioned in the repo, see 8.1): places to visit, cafes and restaurants, parks and outdoor spaces, photography spots, historical places, shopping and markets, weekend activities, sports and fitness, food exploration, tech and professional communities, arts, music and hobbies. Trekking is out of V1 scope (D8).

Do not create thin or duplicated pages to target keywords. Each published page needs unique, verified local information.

### 3.3 Content workflow

Content lives in Git as Astro content collections (MDX and JSON), with typed schemas validated at build time. Publishing is a pull request: preview deployment, review, merge, automatic build and deploy. See 7.5 and 7.6 for rendering and the Gemini studio.

Content collections: `cities`, `categories`, `places`, `articles`, `faqs`, `landingPages`. Every item has `locale` (always `en` in V1), `status`, `reviewedBy`, `reviewedAt` and `lastVerifiedAt`.

### 3.4 Authentication and onboarding

- Google sign-in via Supabase Auth; the verified Google email is the account identity.
- Invite code required during Stage A and B (`invite_codes`), plus Cloudflare Turnstile on sign-up.
- Gmail-only restriction is not used; it adds no real protection.
- **Age gate:** neutral date-of-birth screen; under-18 attempts are blocked and cannot be retried from the same browser for 24 hours. DOB is stored privately and used only to confirm 18+. A "report suspected minor" flow exists (4.4).
- Itemised consent at onboarding (3.4a), a plain-language visibility explanation, and community guidelines acceptance.
- **No phone number is collected.** If SMS verification is introduced later it requires an approved provider, budget, a stated purpose (account recovery or verification), a new consent and a notice update.

**3.4a Consent items (each separate, optional unless marked, logged in `consent_records`)**

- Terms and privacy notice acknowledgement (required).
- Show my profile to other members in discovery (default off).
- Show my city on my profile (default off).
- Email notifications that are not strictly transactional (default off).
- Analytics (default off).
- Contact sharing is consented per connection at the moment of sharing, not at onboarding.

### 3.5 People directory (members-only, gated unlock)

The directory and connection requests unlock for a city only when **both** are true: at least 150 members in that city have discovery enabled, and a trained backup moderator is on the roster (section 12). Until then members can attend meetups, see who else is in a meetup they have joined, and are told the directory is coming.

Once unlocked:
- Search by display name (minimum 3 characters, prefix or trigram), filter by city, interests and intent (friends, group activities, professional networking, exploring places).
- Cursor pagination, 20 cards per page, maximum depth of 10 pages per query, rounded totals only.
- Sort by relevance or recently joined. No "last active", online status or precise location.
- No age filter in V1.
- Per-member profile-view budget (L1 default 100 per day) and per-IP limits to deter scraping; anomalous browsing raises an alert.

Privacy defaults:

| Data | Behaviour |
|---|---|
| Display name | Members only, when discovery is enabled |
| Email | Always private; never returned by any member-facing API |
| Date of birth | Always private |
| City | Members only, only if the user enabled city visibility |
| Photos | Members only, per-photo visibility, blocks respected both ways |
| Exact location | Never collected or shown |
| Contact handles | Visible only to the one connection they were shared with |

Individual profile pages and listing pages are `noindex`, excluded from the sitemap and disallowed in `robots.txt`.

### 3.6 Profiles

Public-safe `profiles` fields: opaque public ID, display name, primary city, bio (plain text only, no links or markdown), interests, optional profile intent, discovery flag, city-visible flag, profile status, timestamps. Private fields (`app_private.profile_private`): DOB, 18+ confirmation timestamp, notification and request preferences. See 8.3 for the exposure rules.

### 3.7 Profile photos

- Profile photo plus up to **6 additional photos in beta** (`MAX_ADDITIONAL_PHOTOS`, configurable; raise toward 10 only after Pro and an egress review, D3).
- Visibility values: `private` (owner only), `connections`, `members`. Defaults: profile photo `members`, additional photos `connections`. There is no anonymous visibility.
- **All user photos live in a private bucket.** Access is only through short-lived signed URLs (5 to 10 minute TTL) created in batch after an authorisation check that applies visibility, blocks, moderation status and connection status. Random UUID object names; never guessable paths.
- **Upload pipeline:**
  1. Client resizes and re-encodes to WebP/JPEG, which strips EXIF and GPS metadata.
  2. Allowed types JPEG, PNG, WebP only (no SVG); size cap 5 MB before resize; dimension limits.
  3. Two stored variants: thumbnail (about 320 px, target 15 to 25 KB) and display (max 1080 px, target 100 to 180 KB), plus a tiny blur placeholder stored in the database.
  4. Server-side validation: magic-byte MIME check, dimensions, size, and rejection of any file that still contains EXIF/GPS markers. A database trigger enforces the photo cap and a storage policy restricts object paths to the owner.
  5. Moderation state `pending`, then `approved` or `rejected`. Pending photos are visible only to the owner. New (L0) accounts have every photo reviewed manually; automated screening (a free-quota safe-search API or an open-source NSFW classifier, evaluated in Phase 6) runs first.
  6. A perceptual hash is compared against the banned-photo hash list (4.5).
- Orphan sweep: a scheduled job reconciles storage objects and `profile_photos` rows.
- Budgets (verify current limits): at about 170 KB per photo and 7 photos per user, 1 GB holds roughly 800 users on free tier. A 20-card directory page costs about 400 KB, so the 5 GB free egress covers roughly 12,000 page views per month. Pro raises both substantially; Cloudflare R2 behind an authorising Worker is the later option if egress grows.

### 3.8 Meetups and group outings (the wedge)

V1 categories: cafe and food outings, photography walks, city cycling and walking groups, sports and fitness in public grounds, movies and cultural outings, local exploration inside the city, tech, professional and hobby meetups. Women-only and women-led meetups are a labelled type (see 4.3).

Out of scope for V1 (D8): trekking, overnight trips, outstation day trips, organised transport, events centred on alcohol, and any event open to under-18s.

Features:
- Public listing by city, category and date; detail page with title, description, time, host display name, venue name and locality, capacity and attendee count.
- **Exact meeting-spot note** (for example "Gate 2, near the ticket counter") is shown only to approved attendees and the host.
- Authenticated join request; host approves or auto-approves within capacity. Capacity enforced transactionally.
- Attendee list (display names) visible only to the host and approved attendees.
- Host can edit, cancel (with a reason) and remove attendees. Cancelling notifies everyone through all channels (3.9).
- Host check-in marks attendance (`attended`), which feeds trust levels and metrics.
- Private post-event feedback prompt ("Did you feel safe? Would you attend again?"), reviewed by the safety lead.
- Report event or host from every meetup page.
- Public venues only; no home addresses. No ticketing or payments.

**Host controls and liability:**
- Host agreement and `host-guidelines` acceptance before the first event. New hosts are vetted by an admin (video or phone call, social profile check, local reference where possible) before approval.
- First three events by a host: capacity of 15 or fewer, public venue only, admin sees the event before publication.
- Attendees acknowledge participation at their own risk and the safety guidance when joining. Terms of service and the host agreement are drafted by counsel, who also reviews limitation-of-liability wording.
- Each meetup page links to the Safety Center (public venue, tell someone, arrive and leave in daylight where possible, report concerns, emergency 112).
- Event structured data (`Event`) is output only for approved, accurate, current events.

### 3.9 Notifications

Channels: in-app (always), email, and Web Push (PWA, opt-in).

| Event | In-app | Push | Email |
|---|---|---|---|
| Connection request received | Yes | If opted in | Yes (generic text, no sender message or name) |
| Request accepted | Yes | If opted in | Yes |
| RSVP approved or declined | Yes | If opted in | Yes |
| **Meetup cancelled or materially changed** | Yes | Yes (priority) | Yes (priority) |
| Meetup reminder (24 hours and 2 hours before) | Yes | If opted in | 24-hour only |
| Moderation outcome affecting the user | Yes | No | Yes |

Design rules:
- A `notification_outbox` with idempotency keys, retry with backoff, and delivery status; sending runs from scheduled functions (see 7.3).
- Emails never contain another member's message, photo or phone/handle; they say "you have a new request, open ApnaCircle". Batch non-urgent emails to at most one per 6 hours.
- Preference centre with per-channel toggles; non-transactional email carries an unsubscribe link and is off by default.
- Quiet hours 22:00 to 08:00 IST for push, except cancellations within 6 hours of start.
- Ask for push permission only after a value moment (after the first RSVP), never on first visit. iOS requires the PWA to be installed to the home screen.
- Email provider: Supabase auth email is for testing only; use Resend (or equivalent) with a verified sender domain for product email; check quotas.

### 3.10 Languages

**English only at launch (D5).** The build stays language-ready so Hindi can be added later without rework:
- No hard-coded UI strings: all text comes from typed message catalogues (JSON) with a CI check for missing keys.
- Content items carry a `locale` field (always `en` in V1); `lang="en"` is set on every page.
- Layout avoids fixed-width text containers, so longer strings fit later.
- Search uses `unaccent` and `pg_trgm`; user-generated text may be in any script, including Devanagari.
- Accepted risk: part of the Saharanpur audience reads Hindi more comfortably and local searches are often in Hindi or Hinglish, so English-only may reduce sign-up and search reach. Review this after Stage B using sign-up drop-off, support messages and member feedback.
- **Hindi gate (post-launch):** add Hindi only when a qualified Hindi reviewer is available, and add it in this order: onboarding, consent and policy pages (legal text is never machine-translated without qualified review), Safety Center, then the rest of the UI and content. Adding it then means Astro i18n routing (`/hi/`), `hreflang` tags, a Devanagari font subset and a Hindi review step in the Content Studio.

### 3.11 Feedback and reports

`/feedback`: bug, feature request, suggestion, content correction, other; subject, description, optional screenshot (same upload validation as photos, stored privately), optional reply email. Cloudflare Turnstile and rate limits are in place from Phase 1.

Safety reports are separate (section 4.4) and available on every profile, photo, meetup and connection. Anonymous reporting is allowed where the target is public (meetups, public content); member-targeting reports require sign-in so they can be rate-limited and de-duplicated, with the reporter's identity never shown to the reported user.

---

## 4. Trust and safety system

### 4.1 Trust levels and request limits

Replaces the 100/day ceiling of v1.0 (retired; it is not an acceptable abuse limit).

| Level | How earned | New requests per day | Burst | Notes |
|---|---|---|---|---|
| L0 New | Signed up, profile not complete, under 7 days old, or no approved photo | 0 (cannot send) | n/a | Can join meetups; every photo manually reviewed |
| L1 Established | 7 days or more, profile complete, approved photo, no upheld reports | 10 | 3 per 10 min | Default request level |
| L2 Trusted | Host-confirmed attendance at 1 or more meetups, or 2 or more accepted connections, and no upheld reports in 90 days | 20 | 5 per 10 min | Absolute platform ceiling is 20 per day |
| Restricted | Auto or manual: see below | 0 | n/a | Moderator review required |

Limits live in a `rate_limit_config` table so they can be tuned without a deploy.

Rules enforced inside a single PostgreSQL transaction or RPC (never client-side):
- Atomic daily counter, using the **IST (Asia/Kolkata) calendar day** so reset information makes sense to users. Requests are counted when created; cancelling does not refund the count.
- Burst limit, maximum 25 outstanding pending requests per sender, no self-requests, no duplicates, blocked users cannot send, recipient preferences are respected.
- Requests expire after 30 days (`expired`).
- Return `429` with a clear reset time.

### 4.2 Cooldowns, silent decline and auto-restriction

- Sender cannot re-request the same person: 90 days after a decline, 30 days after expiry, 7 days after sender cancellation, never after a block.
- **Declines are silent.** The sender sees "Pending" until expiry, then "No response". The decline is recorded internally.
- Auto-restriction: 5 or more declines, or reports from 2 or more distinct members, in a rolling 7 days sets the sender to Restricted and opens a moderation case.
- Recipient controls: pause all requests; accept only from members with an approved photo at L1 or above (default); accept only from people they have attended a meetup with; block, report and hide from search at any time.

### 4.3 Safety by design, including women's safety

- Safe defaults: discovery off, city hidden, photos limited, request filter on.
- One-tap report and block on every card, profile, photo and meetup. Blocking is instant, requires no moderator and never notifies the blocked person; blocking is mutual invisibility.
- A **Safety Center** (`/safety`): meeting safely, spotting scams and pressure, what to do if something goes wrong, how to report, emergency 112, cybercrime reporting at cybercrime.gov.in.
- Women-only and women-led meetups use an optional, private, self-declared field used only for eligibility. The plan documents the limitation (self-declaration cannot be fully verified), so these meetups additionally require admin-approved hosts and a lower capacity cap.
- Zero-tolerance categories with immediate suspension pending review: suspected minors, non-consensual intimate imagery, threats, targeted harassment, impersonation.

### 4.4 Moderation operations

Owner of record: a named Trust and Safety lead plus a trained backup (D6). Coverage target 09:00 to 21:00 IST, seven days a week during Stage B and C, with an after-hours contact route for P0 cases.

| Priority | Examples | Acknowledge | Action taken |
|---|---|---|---|
| P0 | Suspected minor, non-consensual intimate imagery, threats, imminent harm | 2 hours | 24 hours (suspend first, review after) |
| P1 | Harassment, impersonation, unsafe meetup, scam | 24 hours | 72 hours |
| P2 | Spam, low-level guideline breaches, feedback | 72 hours | 7 days |

Process:
- Moderation queue with status, priority, SLA clock, reviewer and resolution note.
- **Evidence snapshot:** content is copied immutably at report time so deleting the content does not destroy evidence.
- Append-only `moderation_actions` and `audit_log`; every sensitive admin read or change is logged.
- Sanction ladder: warning, 7-day restriction, suspension, permanent ban. Zero-tolerance cases skip steps.
- Appeals within 14 days, reviewed by a different person where possible; outcomes notified to the user.
- Escalation: emergencies to 112; criminal matters to police or cybercrime.gov.in with preserved evidence and counsel advice; lawful orders handled under the process in 5.2.
- Pre-launch tabletop drill covering a P0 case; weekly review of the SLA dashboard during beta.
- **Capacity rule:** invites are throttled to moderation capacity (initial hypothesis: no more than 500 active members per trained moderator).

### 4.5 Identity, ban evasion and fake accounts

- Hashed (salted) Google subject ID and normalised email (Gmail dots and plus-tags removed) are stored in `banned_identifiers`; re-registration is blocked.
- Perceptual hashes of photos from banned accounts are stored in `banned_photo_hashes`; matching uploads are held for review.
- Invite codes in beta, Turnstile and per-IP limits on sign-up, trust levels that gate capabilities.
- IP and device signals are used for abuse scoring only, retained briefly and never shown to other users.
- Optional photo or video verification and phone OTP are post-V1 options, to be added only with a budget and a privacy review.

---

## 5. Privacy, compliance and legal readiness

> [!WARN] This section is general guidance, not legal advice. Have your legal counsel or internal legal team confirm applicability, wording and commencement dates (the Digital Personal Data Protection Rules are being phased in) before public launch.

### 5.1 Digital Personal Data Protection (DPDP) workstream

- **Role and inventory:** ApnaCircle is the Data Fiduciary. Maintain a data inventory: each field, its purpose, lawful basis, who can read it, where it is stored and its retention period. Collect nothing without a purpose (this is why phone is out).
- **Notice and consent:** itemised notice in English (counsel to confirm that English alone satisfies the language requirement for your audience, and whether a Hindi notice is advisable) stating what is collected, why, how to withdraw consent, how to exercise rights and how to complain to the Data Protection Board. Consent is free, specific, informed and unambiguous; withdrawing is as easy as giving it. Each consent in 3.4a is logged with notice version, timestamp and locale.
- **Retention schedule (initial proposal):**

| Data | Retention |
|---|---|
| Active account data | While the account is active |
| Deleted account | 14-day grace period, then purged from DB, storage, push subscriptions and analytics identifiers |
| Reports, evidence and moderation records | 12 months after closure, minimised identifiers, longer only if counsel advises (for example a legal hold) |
| Security and audit logs | 12 months (confirm against the Rules) |
| Application and error logs | 90 days, no personal content |
| Backups | Roll off within 35 days; a `deletion_ledger` is re-applied after any restore so deleted users do not reappear |

- **Data Principal rights flows:** access/export (JSON download), correction (profile editor), erasure (self-serve delete), grievance (`/grievance`), and nomination. Requests are tracked in `data_requests` with an internal 7-day response target.
- **Security safeguards:** encryption in transit and at rest, access control with MFA for staff, logging, tested backups and restoration, and the controls in section 9.
- **Breach runbook:** triage, containment, scoping, user and Board notification within the legally required timelines (counsel to confirm; plan for a detailed report within 72 hours), post-incident review.
- **Processors:** record data processing terms for Supabase, Cloudflare, the email provider and the analytics provider; disclose that processors may be located outside India; keep the database in the Mumbai region.
- **Children:** the age gate in 3.4, the suspected-minor P0 flow, and no profiling or targeted advertising of any user.
- **Analytics and cookies:** PostHog loads only after consent, with no session replay, no capture of free-text fields, and in-memory-only persistence before consent.

### 5.2 IT Rules 2021 intermediary checklist (confirm with counsel)

- Publish the rules and regulations, privacy policy and user agreement, prohibiting the content categories the Rules list, and remind users periodically.
- Publish the name and contact of the **Grievance Officer** on `/grievance`; acknowledge complaints within 24 hours and resolve within 15 days.
- Remove or disable access to non-consensual intimate imagery and impersonation content within 24 hours of a complaint.
- Retain information about removed content and the account for the legally required period; keep a documented process for lawful orders and law-enforcement requests, including timelines.
- Keep a log of grievances, actions and timings.

### 5.3 Policies to draft and publish

Eight policy pages are drafted in the `apnacircle-policies/` folder, aligned with this plan and ready for counsel review:

| Page | Route | Draft file |
|---|---|---|
| Privacy Notice | `/privacy` | `01-privacy-notice.md` |
| Terms of Service | `/terms` | `02-terms-of-service.md` |
| Community Guidelines | `/community-guidelines` | `03-community-guidelines.md` |
| Host Guidelines and Agreement | `/host-guidelines` | `04-host-guidelines-and-agreement.md` |
| Safety Center | `/safety` | `05-safety-center.md` |
| Grievance and Appeals | `/grievance` | `06-grievance-and-appeals.md` |
| Cookie and Analytics Notice | `/cookies` | `07-cookie-and-analytics-notice.md` |
| Law Enforcement Requests Policy | `/legal/requests` | `08-law-enforcement-requests-policy.md` |

Rules for the policy pack:
- The drafts are not legal advice. Counsel fills the placeholders (entity, address, Grievance Officer, jurisdiction) and confirms every clause, especially liability, indemnity, governing law, response-time promises, retention periods and the processor list. `00-README-legal-review.md` lists these open items.
- Each page is stored as a versioned content item, published in English, with the version and effective date shown. Previous versions are archived, and material changes re-prompt consent where required.
- Policies may only state what the product actually does. Any change to data fields, processors, retention, limits or response times updates the matching page in the same pull request.
- Every response-time or retention promise on a policy page maps to a monitored control (SLA dashboard, retention job, deletion job).
- Policies are linked from the footer, onboarding consent screen, meetup pages (Safety Center, Host Guidelines) and the report dialog.

---

## 6. UI and design direction

**Product feel:** friendly, modern, welcoming and trustworthy; not a generic dating-app look.

- Warm off-white background, deep ink/navy text, one confident accent (indigo, cobalt or teal), a warm secondary accent.
- Large, clear typography, generous whitespace, rounded cards (12 to 18 px), subtle borders, restrained shadows.
- Real local imagery; no AI-generated people, fake attendee counts or fake activity.
- Clear empty states and plain-language privacy and safety explanations at the point of use.
- Avoid heavy gradients, swipe mechanics, fake online indicators, auto-play video and login walls on public pages.

**Key screens:** homepage and city selector; city and category pages; meetup list and detail; create/edit meetup; sign-in and onboarding (age gate, consent, visibility explanation); profile editor and photo privacy manager; people directory and profile (after unlock); requests inbox and outbox; notifications and preferences; Safety Center; feedback and report forms; moderation dashboard; Content Studio review (pull request).

**Components:** `AppHeader`, `MobileNavigation`, `CitySwitcher`, `LanguageSwitcher`, `SearchInput`, `FilterDrawer`, `PersonCard`, `PlaceCard`, `ArticleCard`, `MeetupCard`, `EventStatusBadge`, `VisibilityControl`, `PhotoUploader`, `ConnectionRequestDialog`, `ConfirmActionDialog`, `ReportDialog`, `BlockDialog`, `ConsentToggle`, `EmptyState`, `SkeletonCard`, `ErrorState`, `Toast`, `Pagination`.

Use Tailwind CSS v4 and the Zentauri UI library where suitable; audit for accessibility and bundle size.

**Accessibility:** keyboard navigation, visible focus, semantic headings and buttons, labels and error messages, alt text, WCAG AA contrast, reduced-motion support, focus-managed dialogs, tested at 200% zoom.

---

## 7. Technology plan

### 7.1 Stack

| Layer | Beta (Stage A and B) | Public launch baseline | Notes |
|---|---|---|---|
| Frontend | Astro + React islands + TypeScript, language-ready (English only in V1) | Same | Static-first |
| Hosting | Cloudflare Workers (static assets plus SSR) | Workers Free, or Paid if CPU/request limits are hit | Prefer Workers for new projects; verify current Pages status |
| Content | Astro content collections in Git | Same | Preview deploys per PR |
| Content Studio | GitHub Action calling Gemini, opens a draft PR | Same | Key held only in GitHub secrets |
| Database, Auth, Storage | Supabase Free, Mumbai region, separate staging and prod projects | Supabase Pro | Region cannot be changed later |
| Server logic | Astro server endpoints and Postgres RPC | Same | See 7.3 |
| Scheduled jobs | `pg_cron` plus Supabase Edge Functions | Same | Notifications, expiry, reconciliation |
| Rate limits | Postgres RPC plus one Cloudflare rate-limiting rule | Same | No Redis |
| Email | Resend Free with a verified domain | Resend (paid tier if volume needs) | Supabase default mail is testing only |
| Push | Web Push (VAPID) | Same | Sent from a scheduled function |
| Analytics | PostHog Free, consent-gated | Same | Note cross-border processing |
| Bot protection | Cloudflare Turnstile | Same | Server-side limits still required |
| Monitoring | Cloudflare and Supabase logs, uptime monitor, Sentry free optional | Same | Alerts at 70% and 90% of quotas |
| CI/CD | GitHub Actions, Dependabot, CodeQL, gitleaks | Same | Private-repo branch protection may need a paid GitHub plan, or use a public repo |
| Domain | Provider subdomain | Custom domain | Registration is not free |

### 7.2 Free-tier realities that still apply in beta

- **Supabase Free:** about 500 MB database, 1 GB storage, 5 GB egress, no automatic backups, and projects pause after inactivity. The nightly backup job (9.4) also keeps the database active. Verify current numbers.
- **Cloudflare Workers Free:** about 100,000 requests per day and a 10 ms CPU limit per invocation. Keep SSR light; measure CPU on every dynamic route.
- **Gemini free tier:** quotas and models change; data may be used to improve Google products, so only public, non-personal inputs are ever sent.
- **Email, SMS and domains** are not guaranteed free. SMS is not used in V1.
- Where possible avoid adding a payment card; if one is required, set caps and alerts first.

### 7.3 Server logic boundaries

- Astro server endpoints (Astro Actions or API routes) call Supabase with the **user's JWT**, so RLS applies. Sensitive multi-step operations (send request, join meetup, change trust level) are Postgres RPC functions, `SECURITY INVOKER` by default; `SECURITY DEFINER` only where unavoidable, with `set search_path = ''`, narrow inputs and tests.
- The Supabase **service-role key never reaches Workers or the browser.** It is used only in scheduled Edge Functions and CI jobs that need it.
- Edge Functions are limited to scheduled and webhook work: notification delivery (email and push), request expiry, photo orphan sweeps, backup helpers. No request-path hop through Edge Functions.
- Admin and moderator roles are set in `app_metadata` only by SQL or the service role, never by users. Admin routes require MFA (AAL2) enforced both in the app and in RLS/RPC checks.

### 7.4 Environments and regions

- Local: Supabase CLI plus Astro dev server. Staging and production are separate Supabase projects (the free plan allows two). Seed/demo data is labelled and never loaded into production.
- Supabase region: Mumbai (ap-south-1), chosen at project creation.
- Secrets in GitHub Actions and Workers secret stores; `.env` files never committed; gitleaks in pre-commit and CI.

### 7.5 Rendering and cache strategy

- Editorial pages (city, category, place, article, policy, Safety Center) are **static**, built from Git content. Publishing means merge to `main`, which triggers a build and deploy; the content volume is low, but check build quotas.
- Dynamic pages are SSR (`prerender = false`): meetup listing and detail (public, 60-second edge cache), all members-only routes (never publicly cached), account and admin pages.
- There is no ISR; do not promise per-page revalidation. If SSR CPU limits are hit, move to Workers Paid before adding infrastructure.
- Already-built static pages keep working if Supabase is down; dynamic features degrade to a friendly status page.
- Members-only responses carry `Cache-Control: private, no-store`; shared caches are never used for user-scoped data.

### 7.6 Content Studio (Gemini)

**Operating model:** owner-triggered GitHub Action (`workflow_dispatch`, restricted to the owner). It reads a **fact pack**, asks Gemini to structure and write, validates, and opens a **draft pull request**. The public site never calls Gemini.

1. Owner selects city, content type and topic, and supplies or selects a fact pack (YAML of verified facts with source links, taken from the `places` collection or the owner's own notes).
2. The Action sends only public, non-personal inputs to a free-tier model chosen after checking current quotas. No search grounding.
3. Output is JSON validated by Zod: title, slug, summary, sections, FAQs, SEO fields, and a `claims[]` list where every claim is tagged `fact_pack`, `general_knowledge` or `unverified` with its source reference.
4. The PR contains the MDX file, the AI run log (model, prompt version, timestamp) and a verification checklist.
5. **Blocking CI gate:** the PR cannot merge while any claim is `unverified`, or while `reviewedBy`, `reviewedAt`, `lastVerifiedAt` or image-rights fields are missing, or while the page has no first-hand local element (own photo or visit note).
6. Owner reviews the preview deployment, edits, and merges to publish.

Cost and abuse controls: at most 5 drafts per run and 1,200 words each; duplicate-topic detection against existing slugs and titles; at most 10 new pages per week; a kill switch (disable the workflow or delete the secret); the Gemini key comes from a project **without billing enabled** so charges cannot occur (calls simply fail at quota); prompts are versioned. Treat place names, addresses, hours and claims as unverified until checked. Optional on-page disclosure: "Drafted with AI assistance and reviewed by <name>".

Payload CMS is deferred (ADR-001). Adopt it only if at least two non-technical editors join or editorial volume exceeds what pull requests handle. Appendix A lists what must be done if you keep it.

---

## 8. Architecture and data model

### 8.1 Repository and sources of truth

```text
GitHub monorepo
  apps/web        Astro + React (Cloudflare Workers)
  content/        MDX and JSON content collections (en)
  packages/ui     shared UI / Zentauri integration
  packages/types  shared TypeScript + Zod contracts, cities and categories source
  packages/i18n   message catalogues
  supabase/       migrations, seeds, tests, Edge Functions
  .github/        CI, security gates, content studio, backup workflows
```

**Single source of truth:** cities and categories are defined once in `packages/types/data/`; migrations seed the database from that file, and the content build fails if an item references an unknown slug. Profiles, connections and meetups exist only in the database.

### 8.2 Modules

`auth`, `profiles`, `profile-media`, `discovery`, `connections`, `meetups`, `cities`, `places`, `notifications`, `feedback`, `reports-moderation`, `trust`, `compliance`, `admin`.

### 8.3 Data exposure rules (fixes row-versus-column leakage)

- Only the `public` schema is exposed through the Supabase API. It contains member-safe tables and views only.
- Sensitive data lives in `app_private` (not exposed): DOB, consent records, preferences, banned identifiers, hash lists, data requests.
- Row Level Security is enabled and forced on every table. Default deny; separate policies per role.
- Views use `security_invoker = true`. Column privileges are revoked from `anon` and `authenticated` by default and granted per column.
- The member directory reads from a view or RPC that returns only approved columns.
- Automated tests assert that no sensitive column is selectable by `anon`, `authenticated` (another user), a blocked user, or a moderator, and that Security Advisor and `supabase db lint` pass in CI.

### 8.4 Core tables

```text
profiles                id (references auth.users), public_id (opaque), display_name,
                        primary_city_id, bio, discovery_enabled, city_visible,
                        intent, profile_status, trust_level, created_at, updated_at
app_private.profile_private   profile_id, date_of_birth, age_confirmed_at, preferences
app_private.consent_records   user_id, purpose, granted, notice_version, locale, created_at
interests, profile_interests
profile_photos          id, profile_id, storage_path, thumb_path, blur_data, visibility
                        (private|connections|members), sort_order, moderation_status,
                        phash, created_at
cities, categories      seeded from packages/types/data
connection_requests     id, sender_id, receiver_id, intro_message, status
                        (pending|accepted|declined|cancelled|expired), expires_at,
                        created_at, updated_at
connections             id, user_low, user_high (canonical order), status (active|removed),
                        created_at, removed_at, removed_by
connection_blocks       blocker_id, blocked_id, created_at
request_preferences     user_id, paused, accept_from (l1_plus_photo|shared_meetup|nobody)
contact_shares          id, connection_id, owner_id, kind (instagram|whatsapp), value,
                        revoked_at, created_at
rate_limit_config       trust_level, daily_limit, burst_limit, burst_window_seconds
daily_request_usage     user_id, usage_date (IST), request_count
hosts                   user_id, status (pending|approved|suspended), approved_by, approved_at
meetups                 id, city_id, host_id, title, slug, description, category_id,
                        venue_name, locality, spot_note (attendee-only), starts_at, ends_at,
                        capacity, women_only, status (draft|pending_approval|published|
                        rejected|cancelled|completed), cancel_reason, created_at
meetup_attendees        meetup_id, user_id, status (requested|approved|declined|cancelled|
                        attended|no_show), created_at
meetup_feedback         meetup_id, user_id, felt_safe, would_return, note
notifications           id, recipient_id, type, entity_id, read_at, created_at
notification_preferences, push_subscriptions
notification_outbox     id, channel, recipient_id, payload, idempotency_key, status,
                        attempts, next_attempt_at
feedback                id, user_id (nullable), category, subject, message,
                        screenshot_path, contact_email, status, created_at
reports                 id, reporter_id (nullable), target_type, target_id, category,
                        description, evidence_snapshot, priority (P0|P1|P2), sla_due_at,
                        status, reviewer_id, resolution, created_at
moderation_actions      id, moderator_id, target_type, target_id, action, reason, created_at
user_sanctions          id, user_id, level, reason, starts_at, ends_at, appeal_status
banned_identifiers      hashed_google_sub, hashed_email, created_at
banned_photo_hashes     phash, created_at
audit_log               id, actor_id, action, target, created_at   (append-only)
data_requests           id, user_id, kind (access|correction|erasure|grievance|nomination),
                        status, due_at, created_at
deletion_ledger         user_id_hash, deleted_at   (re-applied after restore)
invite_codes            code_hash, created_by, uses_left, expires_at
```

Required indexes include `profiles(primary_city_id, discovery_enabled, profile_status)`, `connection_requests(sender_id, created_at)`, `connection_requests(receiver_id, status, created_at)`, a partial unique index on pending requests per sender/receiver pair, `daily_request_usage(user_id, usage_date)` unique, `connections(user_low, user_high)` unique, `meetups(city_id, status, starts_at)`, `meetup_attendees(meetup_id, status)`, `profile_photos(profile_id, sort_order)`, `reports(status, priority, sla_due_at)` and `notification_outbox(status, next_attempt_at)`. Add trigram indexes for display-name search. Use cursor pagination and never `SELECT *`.

### 8.5 Security model summary

- RLS on all tables; only the owner edits their profile and photos; only the recipient accepts or declines a request; block rules enforced in policies and RPCs, not in the UI.
- Photo authorisation checks visibility, moderation status, block state and connection state.
- Admin and moderator permissions are role-based, server-enforced and MFA-protected; moderators cannot bulk-export user data.
- Opaque public IDs (`public_id`) are used in URLs; internal UUIDs are never exposed in member-facing routes.
- All inputs are validated with Zod at every server boundary; user text is rendered as text only.

---

## 9. Security baseline and operations

### 9.1 Application controls

- **Headers:** strict Content-Security-Policy (nonces or hashes, no `unsafe-inline`), HSTS, `X-Content-Type-Options`, `Referrer-Policy`, `Permissions-Policy`, `frame-ancestors 'none'`.
- **Sessions and CSRF:** `HttpOnly`, `Secure`, `SameSite=Lax` cookies; Origin checking on every state-changing endpoint; short admin session lifetimes.
- **Uploads:** see 3.7; no SVG; EXIF stripped and verified; private bucket only.
- **Content safety:** bios and intros are plain text; links are not auto-linked; MDX is trusted only because it comes from reviewed pull requests.
- **Enumeration and scraping defence:** opaque IDs; per-user and per-IP limits on directory, profile and media endpoints; maximum pagination depth; rounded totals; Turnstile on sign-up and on abuse triggers; `noindex` headers and `robots.txt` for members-only and media routes; alerting on abnormal viewing volume.
- **Cloudflare:** one free rate-limiting rule on auth and feedback paths; bot and WAF managed rules where the plan allows.

### 9.2 Supply chain and CI gates

Pinned lockfile; Dependabot; `pnpm audit` gate; GitHub Actions pinned by commit SHA with minimal `GITHUB_TOKEN` permissions; secret scanning and gitleaks; CodeQL on supported repos; branch protection with required reviews and checks (public repo or paid plan); two-factor authentication on every account that can deploy or access data.

### 9.3 Logging and monitoring

Structured logs without tokens, message content or personal data; retention per 5.1. Uptime monitoring; alerts on error rate, auth anomalies, quota usage (70% and 90%) and spend. `/.well-known/security.txt` publishes a vulnerability disclosure contact.

### 9.4 Backups and recovery

- Nightly encrypted logical backup (`pg_dump` via the session pooler or the Supabase CLI) from GitHub Actions, plus a storage-object export, to a private store the team controls; Actions artifacts are only a secondary copy. This starts in **Phase 2**, not later.
- Targets in beta: recovery point 24 hours, recovery time 4 hours. After Pro: use daily managed backups, consider PITR once the community passes about 1,000 members.
- A restore drill runs monthly and before every stage gate; the `deletion_ledger` is re-applied after each restore.
- Note that the Supabase direct connection may be IPv6-only; CI uses the pooler. Test migrations through the same path you use in production.

### 9.5 Incident response

Severity levels, an on-call owner, communication templates, a breach decision tree (5.1), evidence preservation, and a post-incident review. Run a tabletop drill covering a data leak and a P0 safety case before Stage B.

### 9.6 Security verification

OWASP ASVS Level 1 self-assessment, with Level 2 applied to authentication, session and access-control sections; OWASP ZAP baseline scan against staging in CI; the RLS and exposure test suite in section 14; an independent review or penetration test before Stage C (D7).

---

## 10. SEO, AEO and performance

**Indexable:** city landing pages, city and category pages, verified place pages, useful local guides, and approved public meetup pages. **Not indexable:** profiles, member listings, dashboards, filter combinations, media routes and anything private.

Technical SEO: static or server-rendered HTML; unique title and description; canonical URLs; XML sitemap of published indexable pages; `robots.txt`; Open Graph metadata; `BreadcrumbList`, `Article`, `Organization`/`WebSite` schema; `Event` schema only for real, approved, current events; internal links between city, category, place, article and meetup pages; correct redirects and 404s; image alt text, dimensions and lazy loading. Use the city path (for example `/saharanpur/meetups`) as canonical, not query-string variants. Answer real local questions clearly in English, including common Hinglish phrasings in headings and FAQs where natural; do not promise inclusion in AI answers. No fake reviews, fabricated attendance or unverified place details.

Performance: static generation for editorial pages; React islands only where needed; responsive AVIF/WebP images; pagination everywhere; thumbnails in directories; minimal third-party scripts; Core Web Vitals measured on mid-range Android over 4G.

---

## 11. Phased implementation roadmap

Build in vertical slices. Every phase has tests and acceptance criteria. **No external users until Phase 3 is complete.**

### Phase 0: Foundation and compliance kickoff

Deliverables: brand and trademark clearance; monorepo; CI with lint, typecheck, test, build, gitleaks, Dependabot, CodeQL; two Supabase projects in Mumbai; secrets strategy; ADRs (rendering, content in Git, auth and database boundaries, photo storage); draft policies; legal counsel engaged; data inventory started; named trust and safety lead identified.
Acceptance: app runs locally; CI green; no secrets in the repo; ADRs recorded.

### Phase 1: Public site, design system, language-ready build and abuse-resistant forms

Deliverables: Astro shell; Tailwind v4 and Zentauri; typed message catalogues (no hard-coded UI strings, English only); content collections; homepage; Saharanpur city page; category templates; human-written seed content; about page and the eight policy pages (privacy, terms, community guidelines, host guidelines, Safety Center, grievance, cookies, legal requests) published from counsel-reviewed content with version and effective date, in English; feedback page; **Turnstile and rate limits on `/feedback`**; security headers; empty, loading, error and not-found states.
Acceptance: useful HTML without JavaScript; mobile and desktop work; no hard-coded UI strings (CI check passes); headers verified; no login needed to browse public content.

### Phase 2: Supabase, authentication, privacy foundation and backups

Deliverables: migrations and seeds; public/private schema split; RLS and column-privilege tests; Google sign-in; invite codes; Turnstile on sign-up; DOB age gate; consent records and logged notices; roles with MFA for admin; audit log; onboarding (name, city, interests); **nightly encrypted backup and the first restore drill**.
Acceptance: user A cannot read user B's private data; no sensitive column readable by any non-owner role; under-18 attempts blocked; a restore from backup succeeds.

### Phase 3: Trust and safety core (gate for all social features)

Deliverables: report flows and moderation queue with SLA clocks; evidence snapshots; block; sanctions and appeals; `banned_identifiers` and photo-hash tooling; notification infrastructure (in-app, email via verified sender, Web Push, outbox, preferences); account deletion and data export; grievance workflow; Safety Center content; moderation runbook and tabletop drill.
Acceptance: a test P0 report reaches the queue and is actioned within SLA; blocking is instant and mutual; deleting an account purges DB and storage; emails and push deliver; drill completed. Stage A can begin.

### Phase 4: Meetups and the host programme (the wedge)

Deliverables: host application and admin vetting; meetup create/edit/cancel; discovery by city, category and date; RSVP and approval with transactional capacity; attendee-only spot note; check-in and attendance; reminders and priority cancellation alerts; private feedback; women-only type; host agreement and attendee acknowledgement; `Event` structured data; seed host recruitment (5 to 10 local hosts: clubs, cycling and photography groups, cafes) with a host kit.
Acceptance: events always have a city and public venue; no home-address field; capacity stays consistent under concurrent joins; cancellation reaches all attendees through all channels; at least 5 hosts approved.

### Phase 5: Content Studio

Deliverables: Gemini GitHub Action; fact packs; Zod validation; claim tagging and the blocking CI gate; duplicate detection and limits; kill switch; free-tier, no-billing key.
Acceptance: browsing triggers zero AI calls; only the owner can run it; nothing publishes without a merged, reviewed PR; no personal data in prompts.

### Phase 6: Profiles, photos and trust levels

Deliverables: profile editor; photo pipeline with variants, validation, moderation and hash checks; signed-URL authorisation; trust-level computation; unlock rule for the directory; members-only profile view; teaser for logged-out visitors.
Acceptance: private and unapproved photos are unreachable by others (tested); EXIF and GPS absent from stored files; email never in any member-facing payload; directory remains locked until the unlock rule is met.

### Phase 7: Directory and connection requests

Deliverables: directory search, filters, pagination limits; connection requests with trust-tier limits, pending cap, cooldowns, silent decline, auto-restriction; recipient controls; accept, decline, cancel, remove connection, block; explicit per-connection contact sharing with revocation of visibility; expiry job; abuse dashboard.
Acceptance: the request limit for each tier is enforced atomically (concurrency test); duplicates, self-requests and blocked senders are rejected; a declined sender cannot re-request inside the cooldown; contact handles are never shared automatically.

### Phase 8: Hardening, SEO, QA and launch readiness

Deliverables: sitemap, metadata, structured data, Search Console; consent-gated PostHog; Playwright journeys; accessibility and mobile performance pass; independent security review; legal sign-off on policies and the compliance checklist; Launch Baseline provisioned; incident and moderation processes rehearsed.
Acceptance: no critical security or accessibility defects; section 15 checklist complete; Stage B gates met. Stage C begins.

### Phase 9: Expansion gates

Activate a new city only when the expansion criteria in section 12 are met. Order: Roorkee and Muzaffarnagar, then Haridwar and Dehradun, then Meerut.

---

## 12. Metrics and numeric gates

Track events without private content or contact details: `signup_completed`, `age_gate_blocked`, `profile_completed`, `discovery_enabled`, `meetup_viewed`, `meetup_created`, `meetup_joined`, `meetup_attended`, `meetup_cancelled`, `connection_request_sent`, `connection_request_accepted`, `user_blocked`, `report_submitted`, `report_resolved`, `feedback_submitted`, `notification_opt_in`.

The numbers below are **starting hypotheses**; recalibrate with Stage A data, record changes in an ADR, and never loosen a safety gate to hit a growth number.

| Gate | Criteria |
|---|---|
| Stage A exit | At least 5 approved hosts; at least 8 completed meetups; at least 60% of approved RSVPs attend their first meetup; average "felt safe" at least 4 of 5; no unresolved P0; no open severity 1 or 2 security defect |
| Stage B exit | At least 4 meetups a week for 6 consecutive weeks; at least 40% of members join at least one meetup; week-4 retention at least 25%; P0 acknowledged within 2 hours in 100% of cases; P1 and P2 SLAs met in at least 95%; backup restore drill passed |
| Directory unlock (per city) | At least 150 members with discovery on, and a trained backup moderator on the roster |
| Stage C entry | Stage B exit, legal sign-off, independent security review, Launch Baseline provisioned |
| City expansion | 8 weeks of at least 6 meetups a week; at least 10 hosts with 2 or more events in 60 days; week-4 retention at least 25%; request acceptance between 20% and 70% (outside the band means spam or poor matching); report rate below 2% of monthly active members; SLAs met in at least 95% of cases; a named local host lead and 5 pre-recruited hosts in the new city; at least 30 verified content pages ready |

Core measures: profile completion, discovery opt-in, meetup join-to-attendance, repeat participation, request acceptance and decline rates, retention (7 and 30 day), report rate and time to action, notification opt-in and delivery, city-level supply of hosts and events. Do not optimise requests sent or time spent.

---

## 13. Budget and upgrade gates

- **Alpha and closed beta target: ₹0 infrastructure**, excluding the domain and sender domain needed for email.
- **Public launch: Launch Baseline** (section 2), approved and capped.
- Upgrade triggers: Supabase storage, database or egress approaching 70% of quota; need for managed backups or PITR; SSR CPU or request limits reached; email volume beyond the free allowance; analytics or monitoring quotas exceeded; moderation or support needs beyond one person.
- Before enabling any paid service follow the six steps in section 2 and record an ADR.
- Never store irreplaceable user data without a tested export and restore process.

---

## 14. Testing strategy

- **Unit:** Zod schemas, consent and age-gate logic, IST day-boundary logic, trust-level rules, visibility rules.
- **Database (pgTAP and integration):** RLS for every role, column-exposure tests, block rules, duplicate and cooldown constraints, atomic counters under concurrency, capacity under concurrency, photo cap trigger.
- **Security:** IDOR tests for profiles, photos, requests, meetups and reports; scraping and enumeration tests; service-role leakage scan of bundles; upload validation (wrong MIME, SVG, oversized, EXIF/GPS retained); CSRF and Origin checks; header tests; ZAP baseline.
- **Integration:** notification outbox retry and idempotency; email and push delivery; scheduled jobs; backup and restore with the deletion ledger; content CI gate (unverified claims block merge).
- **End to end (Playwright):** browse city, sign in, age gate, consent, join meetup, host cancel with notifications; after unlock: enable discovery, send request, silent decline, cooldown, accept, share contact, remove connection; report and block; account deletion.
- **Language-readiness and accessibility:** hard-coded string and missing-key checks, keyboard flows, focus management, contrast, reduced motion, 200% zoom.
- **Visual:** key screens on mobile and desktop in both languages.

Required scripts (adapt to the package manager):

```bash
pnpm lint
pnpm typecheck
pnpm test
pnpm test:db
pnpm test:e2e
pnpm build
```

Every feature lands in small, reviewable commits with tests and a green build.

---

## 15. Launch checklist

### Product and operations
- [ ] Saharanpur is the only active city.
- [ ] 5 or more approved hosts and a recurring meetup calendar.
- [ ] Directory locked until the unlock rule is met.
- [ ] No in-app chat; contact sharing is explicit and per connection.
- [ ] Meetups use public venues; no trekking, overnight or outstation events.
- [ ] Trust and safety lead and trained backup named; SLA dashboard live; tabletop drill done.

### Privacy, safety and legal
- [ ] Member profiles and photos unreachable when logged out.
- [ ] No phone number collected; email and DOB never in member-facing payloads.
- [ ] Notices, consent log and withdrawal flow live in English.
- [ ] Retention schedule implemented; deletion purges DB, storage and analytics identifiers.
- [ ] Grievance Officer published; grievance and takedown timelines tested.
- [ ] Terms, host agreement and community guidelines reviewed by counsel.
- [ ] DPDP and IT Rules applicability and commencement dates confirmed by counsel.
- [ ] Breach runbook rehearsed; processor terms recorded.

### Engineering
- [ ] RLS, column exposure, rate limits and capacity tests pass.
- [ ] Service-role and Gemini keys are not in any client bundle or Worker.
- [ ] Nightly backups running; restore drill passed within 30 days.
- [ ] Security headers verified; ZAP baseline clean; independent review closed out.
- [ ] Alerts configured for errors, auth anomalies, quotas and spend.

### SEO and content
- [ ] Unique city and category copy in English.
- [ ] No AI-drafted page published without a merged, reviewed PR and verified facts.
- [ ] Sitemap and canonical URLs work; private routes are noindex and robots-disallowed.
- [ ] Place details and sources verified; image rights recorded.

---

## 16. Official references (re-check before implementation)

Plans, quotas, product capabilities and terms change. These are starting points.

- Astro: https://astro.build/ and https://docs.astro.build/
- Astro on Cloudflare: https://docs.astro.build/en/guides/deploy/cloudflare/
- Cloudflare Workers pricing: https://developers.cloudflare.com/workers/platform/pricing/
- Cloudflare Workers limits: https://developers.cloudflare.com/workers/platform/limits/
- Cloudflare Turnstile plans: https://developers.cloudflare.com/turnstile/plans/
- Cloudflare R2 pricing: https://developers.cloudflare.com/r2/pricing/
- Supabase pricing: https://supabase.com/pricing and docs: https://supabase.com/docs
- Supabase row-level security and database linting: https://supabase.com/docs/guides/database/postgres/row-level-security
- Gemini API pricing: https://ai.google.dev/gemini-api/docs/pricing
- PostHog pricing: https://posthog.com/pricing
- Resend pricing: https://resend.com/pricing
- GitHub pricing: https://github.com/pricing
- OWASP ASVS: https://owasp.org/www-project-application-security-verification-standard/
- DPDP Act and Rules and IT Rules 2021 (official texts, MeitY): https://www.meity.gov.in/
- Cybercrime reporting: https://cybercrime.gov.in/

---

## 17. Instructions for the implementation agent

Treat this document as the product scope and architectural guardrail.

1. Do not implement all phases in one change. Start with Phase 0 and Phase 1; present the repo structure, design tokens and page skeleton before moving on.
2. For each phase list files changed, migrations, environment variables, security considerations, tests and acceptance criteria.
3. Follow the phase order. **Never expose a social feature to external users before Phase 3 acceptance passes.**
4. Do not add Redis, a separate backend, Payload, paid APIs or extra infrastructure without evidence and explicit approval (record an ADR).
5. Keep all secrets out of client bundles and Git; the service-role key and Gemini key never run in request paths or browsers.
6. Treat RLS as row-level only: put sensitive columns in the unexposed private schema and test column exposure for every role.
7. Never collect a field without a documented purpose; do not add phone or location collection.
8. Never put private user data in public APIs, analytics, logs or AI prompts.
9. Do not publish AI-generated content without a merged, reviewed pull request and verified facts. Label seed and demo data and never load it into production.
10. Make small commits and run lint, typecheck, tests and build after each slice.
11. If a free-tier limit blocks a requirement, explain it and propose the cheapest compliant option before introducing a paid service.
12. Before every stage gate, perform the privacy, security, abuse and legal-readiness review and a backup restore drill.

**Definition of done for V1:** a real Saharanpur member can safely discover public local content, attend group meetups run by vetted hosts, and receive timely notifications; once the community passes the unlock rule, discover opted-in members, send and receive limited connection requests, and voluntarily share contact details with one connection; report or block anyone instantly; and delete their data. The owner can manage city content and review Gemini-assisted drafts as pull requests without paying for AI on every visit, and trust and safety operates within published response times.

---

## Appendix A. If Payload CMS is kept instead (not recommended for V1)

Adopt only after an ADR showing a real need (for example two or more non-technical editors). Then:

- Run Payload in a separate schema (`schemaName`), disable dev schema `push` in production, use migrations only, and give it a dedicated database role.
- Use the Supabase session pooler or a direct IPv6-capable host for migrations; test prepared-statement behaviour before relying on transaction pooling.
- Configure an S3-compatible media adapter; Render's filesystem is ephemeral.
- Do not run on a 512 MB free instance in production; expect cold starts on free plans and plan for a paid tier.
- Keep cities and categories as the single source (8.1) and reference them by slug.
- Use one identity system for staff with MFA, or document Payload's separate users as a second admin surface with the same controls and audit logging.
- Keep Payload publishing behind a webhook that triggers a normal build; Astro has no per-page revalidation.
