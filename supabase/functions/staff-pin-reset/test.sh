#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Integration tests for the staff-pin-reset Edge Function.
#
# No external API, no rate limiting of its own — safe to run repeatedly.
# Mints real owner / front_desk sessions via staff-login, like supabase/
# rls-test.sh.
#
# PREREQUISITES
#   1. supabase start
#   2. supabase db reset
#   3. supabase functions serve --env-file supabase/functions/.env
#   4. bash supabase/functions/staff-pin-reset/test.sh
#
# Requires: curl, docker (psql — this suite creates its own throwaway target
# staff user so it never mutates a real seeded PIN).
# ---------------------------------------------------------------------------

set -uo pipefail

BASE="${BASE_URL:-http://127.0.0.1:54321}"
RESET_URL="$BASE/functions/v1/staff-pin-reset"
LOGIN_URL="$BASE/functions/v1/staff-login"
DB_CONTAINER="${DB_CONTAINER:-supabase_db_gym-saas}"
PROJECT_DIR="${PROJECT_DIR:-$(dirname "$0")/../../..}"

ORG_IRON=11111111-1111-1111-1111-111111111111
ORG_FLEX=22222222-2222-2222-2222-222222222222
LOC_IRON=aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa

# Throwaway target: a front_desk staffer at Iron Temple.
# id/phone chosen to collide with nothing in seed.sql or any other suite.
# OLD_HASH is a REAL bcrypt(cost 12) hash — it is the seed's own hash for PIN
# 3101 (Kavya Reddy), reused so this suite needs no bcrypt tool and staff-login
# can genuinely verify against it.
TARGET_ID=0daded00-9999-0000-0000-000000000001
TARGET_PHONE=919000077701
TARGET_OLD_PIN=3101
TARGET_OLD_HASH='$2a$12$0AvZqgUK3y9569oqbJXCX.HeztSPoM2Ef2nJmbVlem4zMmkLfh.K.'
NEW_PIN=4321

PASS=0; FAIL=0; SKIP=0
FAILED_CASES=()

if [ -t 1 ]; then
  G=$'\033[32m'; R=$'\033[31m'; Y=$'\033[33m'; B=$'\033[1m'; N=$'\033[0m'
else
  G=""; R=""; Y=""; B=""; N=""
fi

ok()  { PASS=$((PASS+1)); printf '  %sPASS%s  %s\n' "$G" "$N" "$1"; }
bad() { FAIL=$((FAIL+1)); FAILED_CASES+=("$1"); printf '  %sFAIL%s  %s\n' "$R" "$N" "$1"
        printf '        expected: %s\n        actual:   %s\n' "$2" "$3"; }
skipped() { SKIP=$((SKIP+1)); printf '  %sSKIP%s  %s\n           %s\n' "$Y" "$N" "$1" "$2"; }

assert_contains() { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "contains '$2'" "$3" ;; esac; }
assert_equals()   { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "$2" "$3"; fi; }

ANON_KEY="${ANON_KEY:-}"
if [ -z "$ANON_KEY" ] && command -v supabase >/dev/null 2>&1; then
  ANON_KEY=$( (cd "$PROJECT_DIR" && supabase status -o env 2>/dev/null) \
    | sed -n 's/^ANON_KEY="\(.*\)"$/\1/p' | tail -1 )
fi

have_psql=false
if docker exec "$DB_CONTAINER" true >/dev/null 2>&1; then have_psql=true; fi
sql() { docker exec "$DB_CONTAINER" psql -U postgres -d postgres -tAc "$1" 2>/dev/null | tr -d '\r'; }

# ---------------------------------------------------------------------------
# Transport
# ---------------------------------------------------------------------------

# login <org> <phone> <pin> -> access_token ('' on failure)
login() {
  curl -s -X POST "$LOGIN_URL" -H "Authorization: Bearer $ANON_KEY" \
    -H 'Content-Type: application/json' \
    -d "{\"organization_id\":\"$1\",\"phone\":\"$2\",\"pin\":\"$3\"}" \
    | sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p'
}

# reset <bearer> <json-body> -> response body
reset() {
  curl -s -X POST "$RESET_URL" -H "Authorization: Bearer $1" \
    -H 'Content-Type: application/json' -d "$2"
}
reset_status() {
  curl -s -o /dev/null -w '%{http_code}' -X POST "$RESET_URL" \
    -H "Authorization: Bearer $1" -H 'Content-Type: application/json' -d "$2"
}
login_status() {
  curl -s -o /dev/null -w '%{http_code}' -X POST "$LOGIN_URL" \
    -H "Authorization: Bearer $ANON_KEY" -H 'Content-Type: application/json' \
    -d "{\"organization_id\":\"$1\",\"phone\":\"$2\",\"pin\":\"$3\"}"
}

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

reset_state() {
  $have_psql || return 0
  docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -q >/dev/null 2>&1 <<SQL
DELETE FROM login_attempts WHERE phone = '$TARGET_PHONE';
DELETE FROM users WHERE id = '$TARGET_ID';
-- staff-login bridges a first login into auth.users keyed on a synthetic
-- email derived from users.id. This suite reuses a fixed TARGET_ID, so the
-- orphaned auth.users row must go too or the next run's first login fails to
-- re-provision (createUser -> email already exists). Cascades to
-- auth.identities / auth.sessions.
DELETE FROM auth.users WHERE email = '$TARGET_ID@staff.internal.invalid';
SQL
}

arrange() {
  $have_psql || return 0
  docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -q >/dev/null 2>&1 <<SQL
INSERT INTO users (id, organization_id, name, phone, role, location_id, pin_hash)
VALUES ('$TARGET_ID', '$ORG_IRON', 'PIN Reset Target', '$TARGET_PHONE',
        'front_desk', '$LOC_IRON', '$TARGET_OLD_HASH');
SQL
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

printf '\n%s== staff-pin-reset tests ==%s\n' "$B" "$N"
printf 'target: %s\n' "$RESET_URL"

if [ -z "$ANON_KEY" ]; then
  printf '\n%sERROR%s could not determine the anon key. Run `supabase status`.\n\n' "$R" "$N"
  exit 1
fi
if ! $have_psql; then
  printf '\n%sERROR%s this suite needs docker/psql to create its throwaway target user.\n\n' "$R" "$N"
  exit 1
fi
if ! curl -s -o /dev/null --max-time 5 -X POST "$RESET_URL" -d '{}'; then
  printf '\n%sERROR%s cannot reach staff-pin-reset. Start `supabase functions serve`.\n\n' "$R" "$N"
  exit 1
fi

reset_state
arrange

RAVI=$(login "$ORG_IRON" 919000000001 1234)     # Iron owner
PRIYA=$(login "$ORG_IRON" 919000000011 1111)    # Iron front_desk
SANJAY=$(login "$ORG_FLEX" 919000000002 2345)   # FlexFit owner
if [ -z "$RAVI" ] || [ -z "$PRIYA" ] || [ -z "$SANJAY" ]; then
  printf '\n%sERROR%s could not mint sessions via staff-login.\n\n' "$R" "$N"
  exit 1
fi
ok "minted owner / front_desk / other-org-owner sessions"

# ---------------------------------------------------------------------------
# 0. CORS preflight
# ---------------------------------------------------------------------------
printf '\n%s-- CORS preflight --%s\n' "$B" "$N"
pf=$(curl -s -i -X OPTIONS "$RESET_URL" -H "Origin: https://app.example.com" \
  -H "Access-Control-Request-Method: POST" | tr '[:upper:]' '[:lower:]')
assert_contains "OPTIONS preflight answered 200" "http/1.1 200" "$pf"
assert_contains "preflight allows an origin"     "access-control-allow-origin:" "$pf"

# ---------------------------------------------------------------------------
# 1. Input validation
# ---------------------------------------------------------------------------
printf '\n%s-- input validation --%s\n' "$B" "$N"
assert_contains "unparseable body -> 400"          '"error":"invalid_json_body"' "$(reset "$RAVI" 'not json')"
assert_contains "missing target_user_id -> 400"    '"error":"target_user_id_malformed"' "$(reset "$RAVI" '{"new_pin":"1234"}')"
assert_contains "garbage target_user_id -> 400"    '"error":"target_user_id_malformed"' "$(reset "$RAVI" '{"target_user_id":"nope","new_pin":"1234"}')"
assert_contains "missing new_pin -> 400"           '"error":"new_pin_required"' "$(reset "$RAVI" "{\"target_user_id\":\"$TARGET_ID\"}")"
assert_contains "3-digit pin -> 400"               '"error":"pin_malformed"' "$(reset "$RAVI" "{\"target_user_id\":\"$TARGET_ID\",\"new_pin\":\"123\"}")"
assert_contains "non-digit pin -> 400"             '"error":"pin_malformed"' "$(reset "$RAVI" "{\"target_user_id\":\"$TARGET_ID\",\"new_pin\":\"abcd\"}")"
assert_equals   "GET is rejected"                  "405" "$(curl -s -o /dev/null -w '%{http_code}' -X GET "$RESET_URL" -H "Authorization: Bearer $RAVI")"

# ---------------------------------------------------------------------------
# 2. Authorization
# ---------------------------------------------------------------------------
printf '\n%s-- authorization --%s\n' "$B" "$N"
GOOD="{\"target_user_id\":\"$TARGET_ID\",\"new_pin\":\"$NEW_PIN\"}"
assert_equals   "anon key (not a staff session) -> 401" "401" "$(reset_status "$ANON_KEY" "$GOOD")"
assert_contains "front_desk cannot reset a PIN -> 403"  '"error":"not_owner"' "$(reset "$PRIYA" "$GOOD")"
assert_equals   "front_desk gets 403, not 200"          "403" "$(reset_status "$PRIYA" "$GOOD")"
assert_contains "an owner of ANOTHER org -> 404 (same-org only)" '"error":"target_not_found"' "$(reset "$SANJAY" "$GOOD")"
assert_equals   "  ...404, not 200"                     "404" "$(reset_status "$SANJAY" "$GOOD")"
assert_contains "owner + unknown target uuid -> 404"    '"error":"target_not_found"' \
  "$(reset "$RAVI" '{"target_user_id":"0daded00-0000-0000-0000-0000deadbeef","new_pin":"1234"}')"
# the target's hash is still the original after every rejected attempt
assert_equals "target pin_hash unchanged by any rejected call" "$TARGET_OLD_HASH" \
  "$(sql "select pin_hash from users where id='$TARGET_ID'")"

# ---------------------------------------------------------------------------
# 3. The happy path — owner resets a same-org staffer's PIN
# ---------------------------------------------------------------------------
printf '\n%s-- owner resets a same-org PIN --%s\n' "$B" "$N"
got=$(reset "$RAVI" "$GOOD")
assert_contains "owner reset -> ok"                 '"ok":true' "$got"
assert_contains "  ...echoes the target id"         "\"target_user_id\":\"$TARGET_ID\"" "$got"
assert_equals   "  ...pin_hash actually changed"    "1" \
  "$(sql "select (pin_hash <> '$TARGET_OLD_HASH')::int from users where id='$TARGET_ID'")"
assert_equals   "the NEW pin now logs in"           "200" "$(login_status "$ORG_IRON" "$TARGET_PHONE" "$NEW_PIN")"
assert_equals   "the OLD pin no longer logs in"     "401" "$(login_status "$ORG_IRON" "$TARGET_PHONE" "$TARGET_OLD_PIN")"

# ---------------------------------------------------------------------------
# 4. Lockout recovery — a locked-out staffer is freed by the reset
# ---------------------------------------------------------------------------
printf '\n%s-- lockout recovery --%s\n' "$B" "$N"
# Clear the earlier success row from test 3, then inject 5 recent failures so
# staff-login's fixed 15-min lockout window trips (failures must post-date the
# last success to count — see staff_login_lockout_status).
docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -q >/dev/null 2>&1 <<SQL
DELETE FROM login_attempts WHERE phone = '$TARGET_PHONE';
INSERT INTO login_attempts (organization_id, phone, success, attempted_at)
SELECT '$ORG_IRON', '$TARGET_PHONE', false, now() - (g || ' seconds')::interval
FROM generate_series(1,5) g;
SQL
assert_equals "target is now locked out (429)" "429" "$(login_status "$ORG_IRON" "$TARGET_PHONE" "$NEW_PIN")"
assert_contains "owner reset succeeds despite the lockout" '"ok":true' "$(reset "$RAVI" "{\"target_user_id\":\"$TARGET_ID\",\"new_pin\":\"5678\"}")"
assert_equals "  ...login_attempts for that phone were cleared" "0" \
  "$(sql "select count(*) from login_attempts where phone='$TARGET_PHONE'")"
assert_equals "  ...the staffer can log in immediately with the newest pin" "200" \
  "$(login_status "$ORG_IRON" "$TARGET_PHONE" 5678)"

# ---------------------------------------------------------------------------
# 5. An owner may reset their OWN pin (target = caller)
# ---------------------------------------------------------------------------
printf '\n%s-- owner resets own pin --%s\n' "$B" "$N"
RAVI_ID=$(sql "select id from users where organization_id='$ORG_IRON' and phone='919000000001'")
assert_contains "owner resetting their own pin is allowed" '"ok":true' \
  "$(reset "$RAVI" "{\"target_user_id\":\"$RAVI_ID\",\"new_pin\":\"1234\"}")"
# put Ravi's pin back to the seeded 1234 hash so later suites/runs are unaffected
sql "update users set pin_hash='\$2a\$12\$on0RNeDins4a4rqt4Mcpse8sQ/em3Irl1orEyXYomtKV7sH64bpNS' where id='$RAVI_ID'" >/dev/null
assert_equals "Ravi's seeded pin (1234) still works after restore" "200" "$(login_status "$ORG_IRON" 919000000001 1234)"

# ---------------------------------------------------------------------------
reset_state

printf '\n%s== summary ==%s\n' "$B" "$N"
printf '  %spassed %d%s   %sfailed %d%s   %sskipped %d%s\n' "$G" "$PASS" "$N" "$R" "$FAIL" "$N" "$Y" "$SKIP" "$N"
if [ "$FAIL" -gt 0 ]; then
  printf '\n  failing cases:\n'
  for c in "${FAILED_CASES[@]}"; do printf '    - %s\n' "$c"; done
  printf '\n'; exit 1
fi
printf '\n'; exit 0
