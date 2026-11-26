# ApnaCircle policy pack — drafts for legal review

> **These are drafts, not legal advice.** They are written to match the v1.1 product plan (`apnacircle-v1-planning.md`) and to give your lawyer a complete starting point. Nothing here should be published until your legal counsel or internal legal team has reviewed it, filled the placeholders and confirmed it against the laws in force on your launch date.

## Pages in this pack

| File | Public route | Purpose |
|---|---|---|
| `01-privacy-notice.md` | `/privacy` | DPDP-style notice: what is collected, why, retention, rights, processors |
| `02-terms-of-service.md` | `/terms` | User agreement required by the IT Rules, plus meetup and contact-sharing terms |
| `03-community-guidelines.md` | `/community-guidelines` | Prohibited conduct and content; enforcement ladder |
| `04-host-guidelines-and-agreement.md` | `/host-guidelines` | Rules and agreement a host accepts before the first event |
| `05-safety-center.md` | `/safety` | Practical safety guidance for members and attendees |
| `06-grievance-and-appeals.md` | `/grievance` | Grievance Officer, complaint process, takedown, appeals |
| `07-cookie-and-analytics-notice.md` | `/privacy#cookies` or `/cookies` | Cookies, local storage and consent-gated analytics |
| `08-law-enforcement-requests-policy.md` | `/legal/requests` | How ApnaCircle handles lawful orders and police requests |

## What is already filled, and what only you can supply

**Filled from the plan and public facts:** product name (ApnaCircle), cookie and storage names, processor list with data locations (Cloudflare, Supabase Mumbai, Google, Resend, PostHog EU), emergency numbers (112, women's helpline 181, National Cyber Crime Helpline 1930, cybercrime.gov.in), support hours (09:00 to 21:00 IST, matching the moderation plan), proposed jurisdiction (Saharanpur, Uttar Pradesh, the launch city), retention periods and response targets (taken from plan v1.1), and version 1.0.

**Cannot be filled by anyone but you, and must not be guessed:** the legal entity name, registered address, the named Grievance Officer, and your domain and mailboxes. These appear on live legal pages, so a made-up value would be a false statement. I also did not use any email address from this workspace, because it belongs to a different organisation.

**How to finish:**
1. Open `placeholders.json` and fill the empty values (entity, address, domain, officer name; emails are derived from the domain unless you set them).
2. Run `python3 -I fill_policies.py placeholders.json filled`. It writes copies to `filled/` without touching the drafts, lists any token still unfilled, and counts the `[Counsel ...]` and `[Owner ...]` review notes and DRAFT banners still in the text.
3. Give the pages to counsel. Once they clear every note, delete the notes and banners and publish. The script exits with an error until that is done, so it can be used as a pre-publish check in CI.

Facts assumed from plan v1.1 that the build must honour or the pages must be updated: Supabase in the Mumbai region, PostHog EU cloud, cookie names `ac_consent` and `ac_age_block`, 14-day deletion grace, 12-month report retention, 90-day application logs and a 35-day backup roll-off.

## Placeholder reference

| Placeholder | Meaning |
|---|---|
| `[LEGAL ENTITY]` | Registered name of the company or proprietor operating ApnaCircle |
| `[REGISTERED ADDRESS]` | Registered office address |
| `[CONTACT EMAIL]` | General contact address |
| `[PRIVACY EMAIL]` | Address for privacy and data-rights requests |
| `[GRIEVANCE OFFICER NAME]` and `[GRIEVANCE EMAIL]` | Named Grievance Officer resident in India |
| `[EFFECTIVE DATE]` and `[VERSION]` | Set on publication; bump version on every material change and re-collect consent where required |
| `[JURISDICTION]` | Courts and seat of arbitration, if any (counsel to decide) |
| `[BRAND NAME]` | Replace "ApnaCircle" if the working title changes after trademark clearance |

## Commitments in these drafts that need an owner or counsel decision

Policy pages publish promises. Each of these is a commitment your team must be able to keep, so confirm or change them before launch.

1. Response times: grievance acknowledgement in 24 hours and resolution in 15 days; removal of non-consensual intimate imagery and impersonation content within 24 hours; safety-report acknowledgement targets; appeal window of 14 days.
2. Retention periods: 14-day deletion grace, 12-month report and audit-log retention, 90-day application-log retention, 35-day backup roll-off.
3. Liability, indemnity, governing-law and dispute clauses in the Terms.
4. Statements about security measures and breach notification timelines.
5. The list of processors, the data locations and cross-border statements.
6. Anything about refunds, pricing or paid features: **none exists in V1**, and no policy should promise any.

## Language

V1 launches in English only (decision D5). Ask counsel to confirm that an English-only privacy notice and terms are adequate for your audience under current law, and whether a Hindi notice is advisable at launch anyway. When Hindi is added later, a qualified reader must review the Hindi legal text; do not rely on machine translation for these pages, and state which version controls if the two conflict (counsel to decide).

Because the audience may read Hindi more comfortably, keep the English pages in plain, short sentences.

## Keeping policies true

- Each page carries a version and effective date. Keep previous versions archived.
- Do not publish a statement the product does not do. If the implementation differs from a page, fix the page or the product before launch.
- Re-review when you add phone verification, paid features, new processors, new cities, new data fields or new notification channels.
