#!/usr/bin/env bash
set -euo pipefail
PSQL="${TEST_DB_PSQL:?}"
CONN="${TEST_DB_CONN:?}"
OUT="$(mktemp -d "${TMPDIR:-/tmp}/ac-request-race.XXXXXX")"
trap 'rm -rf "$OUT"' EXIT
q() { "$PSQL" "$CONN" -X -q -At -v ON_ERROR_STOP=1 "$@"; }

q >/dev/null <<'SQL'
select t.open_test_directory('saharanpur', 9699, 9700);
select t.make_member(n, 'Request racer ' || n,
  case n when 9602 then 'L2' when 9604 then 'L2' when 9606 then 'L0' when 9607 then 'Restricted' else 'L1' end::public.trust_level)
from generate_series(9601, 9609) n;
update public.profiles set discovery_enabled = true where id in (t.u(9608), t.u(9609));
insert into public.profile_photos (profile_id, storage_path, thumb_path, moderation_status, screening_result)
select t.u(n), 'race-photo-' || n, 'race-thumb-' || n, 'approved', 'clear' from generate_series(9601, 9609) n;
insert into public.daily_request_usage (user_id, usage_date, request_count) values
  (t.u(9601), (now() at time zone 'Asia/Kolkata')::date, 9),
  (t.u(9602), (now() at time zone 'Asia/Kolkata')::date, 19);
insert into public.connection_requests (sender_id, receiver_id, created_at, expires_at)
select t.u(9605), t.u(n), now() - interval '1 day', now() + interval '29 days' from generate_series(9800, 9823) n;
SQL

race() {
  local sender="$1" expected="$2" error="$3" first="$4" count="$5" root="$OUT/$1"
  local barrier
  barrier=$(q -c "select clock_timestamp() + interval '2 seconds'")
  mkdir "$root"
  for ((receiver = first; receiver < first + count; receiver++)); do
    (q -c "select pg_sleep_until('$barrier'::timestamptz); select t.as_user(t.u($sender)); select public.send_connection_request(t.u($receiver), null);" > "$root/$receiver" 2>&1 || :) &
  done
  wait
  local passed rejected
  passed=$( { grep -hEc '^[[:xdigit:]]{8}(-[[:xdigit:]]{4}){3}-[[:xdigit:]]{12}$' "$root"/* || :; } | awk '{n += $1} END {print n + 0}')
  rejected=$( { grep -hFc "ERROR:  $error" "$root"/* || :; } | awk '{n += $1} END {print n + 0}')
  if [ "$passed" -ne "$expected" ] || [ "$rejected" -ne "$((count - expected))" ]; then
    cat "$root"/*
    echo "FAIL: sender $sender got $passed successful requests and $rejected expected rejections"
    exit 1
  fi
}

race 9601 1 'Daily request limit reached' 9700 6
race 9602 1 'Daily request limit reached' 9710 6
race 9603 3 'Request burst limit reached' 9720 8
race 9604 5 'Request burst limit reached' 9730 8
race 9605 1 'Pending request limit reached' 9740 6
race 9606 0 'Sending requests is unavailable' 9750 3
race 9607 0 'Sending requests is unavailable' 9760 3

barrier=$(q -c "select clock_timestamp() + interval '2 seconds'")
for sender in 9608 9609; do
  (q -c "select pg_sleep_until('$barrier'::timestamptz); select t.as_user(t.u($sender)); select public.send_connection_request(t.u($((19217 - sender))), null);" > "$OUT/pair-$sender" 2>&1 || :) &
done
wait
if [ "$(grep -hEx 'ERROR:  Request unavailable' "$OUT"/pair-* | wc -l | tr -d ' ')" -ne 1 ]; then
  cat "$OUT"/pair-*
  exit 1
fi
q -c "select t.ok((select count(*) from public.connection_requests where sender_id in (t.u(9608), t.u(9609))) = 1,
  'simultaneous reciprocal sends create one request');" >/dev/null

q -c "select t.ok((select array_agg(request_count order by user_id) from public.daily_request_usage
  where user_id between t.u(9601) and t.u(9607)) = array[10,20,3,5,1],
  'daily counters match exactly the winning requests under contention');" >/dev/null
q -c "select t.ok((select count(*) from public.connection_requests where sender_id = t.u(9605) and status = 'pending') = 25,
  'pending requests never exceed 25 under contention');" >/dev/null

# If acceptance wins, the block must remove the connection. If the block wins, it must stop acceptance.
IFS='|' read -r request sender receiver < <(q -c "select id, sender_id, receiver_id from public.connection_requests
  where sender_id in (t.u(9608), t.u(9609))")
barrier=$(q -c "select clock_timestamp() + interval '2 seconds'")
(q -c "select pg_sleep_until('$barrier'::timestamptz); select t.as_user('$receiver'); select public.respond_connection_request('$request', true);" > "$OUT/accept-block-accept" 2>&1 || :) &
(q -c "select pg_sleep_until('$barrier'::timestamptz); select t.as_user('$sender'); select public.block_user('$receiver');" > "$OUT/accept-block-block" 2>&1) &
blocking_pid=$!
wait "$blocking_pid" || { cat "$OUT/accept-block-block"; exit 1; }
wait
if grep -i 'error:' "$OUT/accept-block-accept" | grep -Fvx 'ERROR:  Request unavailable'; then
  exit 1
fi
q -c "select t.ok(app_private.is_blocked_pair('$sender', '$receiver')
  and not exists (select 1 from public.connections c where c.status = 'active'
    and c.user_low = least('$sender'::uuid, '$receiver'::uuid) and c.user_high = greatest('$sender'::uuid, '$receiver'::uuid))
  and not exists (select 1 from public.connection_requests where id = '$request' and status = 'pending'),
  'a concurrent acceptance cannot leave an active connection or request after blocking');" >/dev/null

# Sharing and removing serialize, so either order ends with no readable handle.
IFS='|' read -r connection contact < <(q -c "insert into public.connections (user_low, user_high)
  values (t.u(9608), t.u(9700)) returning id, contact_id")
barrier=$(q -c "select clock_timestamp() + interval '2 seconds'")
(q -c "select pg_sleep_until('$barrier'::timestamptz); select t.as_user(t.u(9608)); select public.share_connection_contact('$contact', 'instagram', 'ParallelShare', true, 'contact-sharing-v1');" > "$OUT/share-remove-share" 2>&1 || :) &
(q -c "select pg_sleep_until('$barrier'::timestamptz); select t.as_user(t.u(9700)); select public.remove_connection('$connection');" > "$OUT/share-remove-remove" 2>&1) &
removal_pid=$!
wait "$removal_pid" || { cat "$OUT/share-remove-remove"; exit 1; }
wait
if grep -i 'error:' "$OUT/share-remove-share" | grep -Fvx 'ERROR:  Connection unavailable'; then
  exit 1
fi
q -c "select t.ok((select status = 'removed' from public.connections where id = '$connection')
  and not exists(select 1 from public.contact_shares where connection_id = '$connection' and (revoked_at is null or value <> '')),
  'a concurrent share cannot survive removal');" >/dev/null
