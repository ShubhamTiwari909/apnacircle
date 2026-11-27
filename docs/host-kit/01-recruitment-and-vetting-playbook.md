# Host recruitment and vetting playbook (Stage A)

Goal: **at least 5 approved hosts** (plan section 12) before the first alpha invite, ideally 8 to 10 so a cancellation does not empty the calendar.

## Who to approach (Saharanpur)
- Cycling, running and walking groups; photography clubs and college photography societies.
- Cafes and bookshops that already hold community evenings.
- College clubs (tech, arts, sports) whose events are open to adults.
- Individual organisers already running a recurring WhatsApp-group meetup.

Out of scope for V1 (decision D8): trekking, overnight or outstation trips, organised transport, alcohol-centred events, anything open to under-18s. Say this at the first conversation.

## Outreach message (edit to your voice)
> We are launching ApnaCircle, a safe, city-based way to find group activities in Saharanpur. We are inviting a small number of hosts for the first meetups. We list your event, handle RSVPs and reminders, and you keep running it your way. Would you be open to a 15-minute call?

## Vetting call (record it in the approval notes)
1. Who are you and what do you already run? How long, how often, how many people?
2. Where do you meet? (Public places only. Never a home.)
3. How do you handle someone who makes others uncomfortable?
4. Walk through the Host Guidelines (`/host-guidelines`) and confirm they will accept the agreement.
5. Ask for a public social profile or group page and one local reference who has attended.

Approve only when you have: the call done, the social profile checked, and notes of at least a sentence on what you verified. The system will not accept an approval without a vetting method and notes.

## Recording the decision
Hosts apply while signed in (`apply_as_host`). An admin with MFA reviews the queue (`admin_review_queue`) and decides (`admin_decide_host`). There is no admin screen yet; call these functions from a trusted session, for example the Supabase SQL editor impersonating the admin, or a small internal script using an `aal2` admin session.

## Granting staff roles (SQL editor only, never from the app)
```sql
update auth.users
   set raw_app_meta_data = coalesce(raw_app_meta_data, '{}'::jsonb) || '{"role":"admin"}'::jsonb
 where email = '<admin email>';
```
Use `"moderator"` for the safety lead. Both must enrol Supabase MFA (TOTP) and sign in with it: staff functions require an `aal2` session, so without MFA they refuse. The custom `admin-mfa` function does not produce an `aal2` session.

## First three events per host
Capacity 15 or fewer, public venue, and an admin reviews each event before it goes live. After three approved events the host publishes directly, except women-only events which always need review.
