#!/usr/bin/env bash
# Capacity must hold under concurrent joins/approvals: real parallel sessions, real commits.
set -euo pipefail
PSQL="${TEST_DB_PSQL:?}"; CONN="${TEST_DB_CONN:?}"
q() { "$PSQL" "$CONN" -X -q -At -v ON_ERROR_STOP=1 "$@"; }
ACK="attendee-ack-2026-11-26"
OUT="$(mktemp -d "${TMPDIR:-/tmp}/ac-conc.XXXXXX")"

q -c "select t.make_host(2); $(for i in $(seq 100 149); do echo "select t.make_member($i, 'Racer $i');"; done)" >/dev/null
CAP5=$(q -c "select t.make_meetup(2, 'Race for five seats', 5)")
SOLO=$(q -c "select t.make_meetup(2, 'Same person twice', 5)")
APPR=$(q -c "select t.make_meetup(2, 'Approval race', 2, 'approval')")

# All clients sleep until the same instant so their transactions genuinely overlap
# (otherwise process start-up staggering hides races).
barrier() { q -c "select (clock_timestamp() + interval '4 seconds')::text"; }

join_as() { # user meetup barrier -> prints psql's full output (result or error text)
  "$PSQL" "$CONN" -X -q -At -c "select pg_sleep_until('$3'::timestamptz); select t.as_user(t.u($1)); select public.join_meetup('$2', '$ACK');" 2>&1
}

# 1. 50 different members race for 5 seats
B=$(barrier)
for i in $(seq 100 149); do ( join_as "$i" "$CAP5" "$B" > "$OUT/cap-$i" ) & done
wait
approved=$(cat "$OUT"/cap-* | grep -c '^approved$' || true)
full=$(cat "$OUT"/cap-* | grep -c 'This meetup is full' || true)
db_count=$(q -c "select count(*) from public.meetup_attendees where meetup_id = '$CAP5' and status = 'approved'")
echo "ok? 50 concurrent joins for 5 seats: approved=$approved full=$full db=$db_count"
[ "$approved" = "5" ] && [ "$full" = "45" ] && [ "$db_count" = "5" ] || { echo "FAIL: capacity oversold or lost updates"; exit 1; }
echo "ok - capacity is exact under 50 concurrent joins"

# 2. One member double-clicking: exactly one RSVP wins
B=$(barrier)
for n in 1 2 3 4 5 6 7 8; do ( join_as 100 "$SOLO" "$B" > "$OUT/solo-$n" ) & done
wait
won=$(cat "$OUT"/solo-* | grep -c '^approved$' || true)
dup=$(cat "$OUT"/solo-* | grep -c 'already joined' || true)
rows=$(q -c "select count(*) from public.meetup_attendees where meetup_id = '$SOLO' and user_id = t.u(100)")
[ "$won" = "1" ] && [ "$dup" = "7" ] && [ "$rows" = "1" ] || { echo "FAIL: duplicate RSVP (won=$won dup=$dup rows=$rows)"; exit 1; }
echo "ok - 8 simultaneous joins by one member create exactly one RSVP"

# 3. Approval mode: 10 requests, host approves all 10 in parallel, only 2 seats exist
for i in $(seq 100 109); do join_as "$i" "$APPR" "$(barrier)" >/dev/null & done
wait
B=$(barrier)
for i in $(seq 100 109); do
  ( "$PSQL" "$CONN" -X -q -At -c "select pg_sleep_until('$B'::timestamptz); select t.as_user(t.u(2)); select public.host_decide_attendee('$APPR', t.u($i), 'approve');" > "$OUT/appr-$i" 2>&1 || true ) &
done
wait
appr_ok=$(q -c "select count(*) from public.meetup_attendees where meetup_id = '$APPR' and status = 'approved'")
[ "$appr_ok" = "2" ] || { echo "FAIL: approved $appr_ok people into 2 seats"; exit 1; }
echo "ok - 10 parallel approvals fill exactly 2 seats"
