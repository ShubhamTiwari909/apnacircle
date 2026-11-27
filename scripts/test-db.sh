#!/usr/bin/env bash
# Real database test runner (replaces the old no-op `test:db`).
#
# 1. Starts a throwaway PostgreSQL cluster (or uses TEST_DB_ADMIN_URL if you provide a server,
#    e.g. the Postgres service container in CI).
# 2. Applies Supabase stand-ins, then every migration that works on plain Postgres
#    (004 is skipped because it installs the pg_cron extension; the stubs stand in for pg_cron and
#    pg_net so 005 and 008, and the privileges they set, are exercised).
# 3. Runs supabase/tests/p4/*.sql (plain SQL assertions) and concurrency tests.
# 4. Runs the legacy pgTAP suites only if the pgtap extension is installed.
#
# Usage:  pnpm test:db            (KEEP_TEST_DB=1 keeps the cluster / test database for inspection)
#
#   TEST_DB_ADMIN_URL   A server you control, as a libpq key=value string ("host=... user=...") or a
#                       postgres:// URI. A uniquely named test database is created and dropped.
#   REQUIRE_PGTAP=1     Fail (instead of skipping) when the pgtap extension is not installed.
set -euo pipefail

# Postgres refuses to start under a broken/unset locale (seen on macOS terminals and slim CI images).
export LC_ALL=C LANG=C

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SQL_DIR="$ROOT/supabase"

find_pg_bin() {
  if command -v initdb >/dev/null 2>&1; then dirname "$(command -v initdb)"; return; fi
  for d in /opt/homebrew/opt/postgresql@17/bin /opt/homebrew/opt/postgresql@16/bin \
           /usr/lib/postgresql/17/bin /usr/lib/postgresql/16/bin /usr/local/bin; do
    if [ -x "$d/initdb" ]; then echo "$d"; return; fi
  done
  echo "initdb not found; install PostgreSQL 16+ or set TEST_DB_ADMIN_URL" >&2
  exit 2
}

STARTED_CLUSTER=0
if [ -z "${TEST_DB_ADMIN_URL:-}" ]; then
  PGBIN="$(find_pg_bin)"
  WORK="$(mktemp -d "${TMPDIR:-/tmp}/apnacircle-testdb.XXXXXX")"
  # Loopback TCP on a free port: Unix socket paths are capped at ~103 bytes on macOS and the
  # temp directory is often longer than that.
  PORT="${TEST_DB_PORT:-$(python3 -I -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])')}"
  # --locale=C keeps initdb independent of whatever LANG/LC_* the shell or CI image has.
  "$PGBIN/initdb" -D "$WORK/data" -A trust -U postgres --locale=C -E UTF8 >/dev/null
  "$PGBIN/pg_ctl" -D "$WORK/data" -o "-c listen_addresses=127.0.0.1 -c port=$PORT -c unix_socket_directories= -c fsync=off -c max_connections=100" -l "$WORK/pg.log" -w start >/dev/null
  STARTED_CLUSTER=1
  ADMIN_CONN="host=127.0.0.1 port=$PORT user=postgres"
  stop_cluster() {
    if [ "${KEEP_TEST_DB:-0}" = "1" ]; then
      echo "[test:db] cluster kept running. Connect with: psql \"dbname=${DB:-postgres} $ADMIN_CONN\""
    else
      "$PGBIN/pg_ctl" -D "$WORK/data" -m fast stop >/dev/null 2>&1 || true
    fi
  }
  trap stop_cluster EXIT
else
  PGBIN="$(find_pg_bin)"
  ADMIN_CONN="$TEST_DB_ADMIN_URL"
fi

PSQL="$PGBIN/psql"
DB="apnacircle_test_$$_${RANDOM}"

# Connection string for database $1 on the admin server. Works for key=value strings and for
# postgres:// URIs (appending " dbname=x" to a URI is invalid).
conn_for() {
  case "$ADMIN_CONN" in
    postgres://*|postgresql://*)
      python3 -I -c 'import sys, urllib.parse as u
p = u.urlsplit(sys.argv[1]); print(u.urlunsplit(p._replace(path="/" + sys.argv[2])))' "$ADMIN_CONN" "$1" ;;
    *) echo "$ADMIN_CONN dbname=$1" ;;
  esac
}

"$PSQL" "$(conn_for postgres)" -v ON_ERROR_STOP=1 -q -c "create database $DB" >/dev/null
CONN="$(conn_for "$DB")"
if [ "$STARTED_CLUSTER" -eq 0 ]; then
  # An external server outlives this script, so drop our database when we are done.
  drop_test_db() {
    if [ "${KEEP_TEST_DB:-0}" = "1" ]; then echo "[test:db] database kept: $DB"; return; fi
    "$PSQL" "$(conn_for postgres)" -X -q -c "drop database if exists $DB with (force)" >/dev/null 2>&1 || true
  }
  trap drop_test_db EXIT
fi
export TEST_DB_CONN="$CONN" TEST_DB_PSQL="$PSQL"

run_sql() { "$PSQL" "$CONN" -v ON_ERROR_STOP=1 -q -X -f "$1" >/dev/null; }

echo "[test:db] applying Supabase stand-ins and migrations"
run_sql "$SQL_DIR/tests/_supabase_stubs.sql"
for m in "${MIGRATIONS_DIR:-$SQL_DIR/migrations}"/*.sql; do
  case "$(basename "$m")" in
    # `create extension pg_cron` is not available on plain Postgres; the stubs provide the cron and net schemas.
    004_cron_jobs.sql) echo "  skip $(basename "$m") (creates the pg_cron extension)"; continue ;;
  esac
  echo "  apply $(basename "$m")"
  # One transaction per migration, like the Supabase CLI, so ordering problems (for example using
  # a new enum value in the same file that adds it) show up here and not in production.
  "$PSQL" "$CONN" -v ON_ERROR_STOP=1 -q -X --single-transaction -f "$m" >/dev/null
done

FAILED=0
shopt -s nullglob
for t in "$SQL_DIR"/tests/p4/*.sql; do
  echo "[test:db] $(basename "$t")"
  # Result tables go to /dev/null; assertion notices ("ok - ...") and errors stay visible.
  if ! "$PSQL" "$CONN" -v ON_ERROR_STOP=1 -q -X -f "$t" 2>&1 >/dev/null | sed -e 's/^psql:.*:[0-9]*: NOTICE:  //' -e 's/^/    /'; then FAILED=1; fi
  # pipefail makes the if-condition reflect psql's status
done
for t in "$SQL_DIR"/tests/p4/*.sh; do
  echo "[test:db] $(basename "$t")"
  if ! bash "$t" 2>&1 | sed 's/^/    /'; then FAILED=1; fi
done

if "$PSQL" "$CONN" -X -q -c "create extension if not exists pgtap" >/dev/null 2>&1; then
  for t in "$SQL_DIR/tests/rls_tests.sql" "$SQL_DIR/tests/phase3_tests.sql"; do
    echo "[test:db] (pgTAP) $(basename "$t")"
    # pgTAP reports failures as "not ok" lines and exits 0, so psql's status alone is not enough.
    PGTAP_OUT="$(mktemp "${TMPDIR:-/tmp}/apnacircle-pgtap.XXXXXX")"
    if ! "$PSQL" "$CONN" -v ON_ERROR_STOP=1 -X -q -f "$t" >"$PGTAP_OUT" 2>&1; then FAILED=1; fi
    sed 's/^/    /' "$PGTAP_OUT"
    if grep -Eq '^[[:space:]]*not ok|Looks like you (failed|planned)' "$PGTAP_OUT"; then FAILED=1; fi
    rm -f "$PGTAP_OUT"
  done
elif [ "${REQUIRE_PGTAP:-0}" = "1" ]; then
  echo "[test:db] pgTAP is required (REQUIRE_PGTAP=1) but the extension is not installed"
  FAILED=1
else
  echo "[test:db] pgTAP not installed: skipping legacy rls_tests.sql and phase3_tests.sql (NOT verified here; set REQUIRE_PGTAP=1 to fail instead)"
fi

if [ "$FAILED" -ne 0 ]; then echo "[test:db] FAILED"; exit 1; fi
echo "[test:db] OK"
