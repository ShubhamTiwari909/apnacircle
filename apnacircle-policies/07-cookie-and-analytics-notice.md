# Cookie and Analytics Notice

> **DRAFT for legal review.** Version [VERSION] · Effective [EFFECTIVE DATE]

This notice explains the cookies and similar technologies on ApnaCircle.

## 1. Strictly necessary (always on)

These keep the service working and secure. You cannot switch them off in our settings, and they do not track you across other sites.

| Name or type | Purpose | Duration |
|---|---|---|
| Authentication cookie (`sb-<project-ref>-auth-token`, which may be split into numbered parts) | Keep you signed in and protect your account | Session or up to the sign-in period |
| Security and bot-protection tokens (Cloudflare Turnstile) | Block bots and abuse on sign-up and forms | Short-lived |
| Consent choice (`ac_consent`) | Remember your cookie and analytics choice | Up to 12 months |
| Age-gate flag (`ac_age_block`) | Remember a blocked under-18 sign-up attempt | 24 hours |

[Owner: the build must use these exact names, or this table must be updated. Re-check the list against the live build before publishing.]

## 2. Analytics (only if you accept)

If you accept analytics, we use PostHog to understand which pages and features are used, so we can improve ApnaCircle. We configure it to:

- receive analytics events only after you accept. If you accept, ApnaCircle stores a random identifier with your choice in the first-party `ac_consent` cookie and uses it for those events;
- **not** record sessions or screens;
- **not** capture text you type into forms, photos, messages or contact details;
- use the minimum identifiers needed and keep data for no more than 12 months.

Until you accept, no analytics cookies or identifiers are set and measurement is limited to anonymous, non-identifying server logs.

## 3. Advertising

We do not use advertising or cross-site tracking cookies.

## 4. Your choices

When analytics are available, you can accept or decline them in the first-visit banner and change your choice at any time in **Analytics preferences**, on the **Cookies & Analytics** page linked from the footer. Declining does not limit your use of ApnaCircle. You can also delete cookies in your browser, but you may then need to sign in again.

## 5. More information

See our [Privacy Notice](/privacy) for how we handle personal data, and contact [PRIVACY EMAIL] with questions.
