#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# RLS + custom-access-token-hook integration tests.
#
# Sibling to supabase/functions/run-all-tests.sh, not inside it: this suite
# hits PostgREST directly (/rest/v1/<table>), not /functions/v1/*, using REAL
# sessions minted by staff-login — a different surface than every per-function
# test.sh, so it lives here instead of being folded into either.
#
# PREREQUISITES
#   1. supabase start
#   2. supabase db reset                 # applies migrations + seed.sql
#   3. supabase functions serve --env-file supabase/functions/.env
#   4. bash supabase/rls-test.sh
#
# Requires: curl, docker (for fixture setup — several cases below need data
# that doesn't exist in seed.sql, e.g. a second Iron Temple location, so this
# suite is not degrade-to-SKIP without psql the way some function suites are).
# ---------------------------------------------------------------------------

set -uo pipefail

BASE_URL="${BASE_URL:-http://127.0.0.1:54321}"
FUNCTIONS_URL="$BASE_URL/functions/v1"
REST_URL="$BASE_URL/rest/v1"
DB_CONTAINER="${DB_CONTAINER:-supabase_db_gym-saas}"
PROJECT_DIR="${PROJECT_DIR:-$(dirname "$0")/..}"

# Seeded fixtures (see supabase/seed.sql)
ORG_IRON=11111111-1111-1111-1111-111111111111
ORG_FLEX=22222222-2222-2222-2222-222222222222
LOC_IRON=aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa
LOC_FLEX=bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb

# Second Iron Temple location + member, created by this suite (NOT in
# seed.sql — every seeded org has exactly one location, which makes it
# impossible to prove front_desk is scoped to THEIR location and not just
# "the org's only location"). Cleaned up by reset_state().
LOC_IRON_2=0daded00-1111-0000-0000-000000000002
MEMBER_LOC2=0daded00-1111-0000-0000-0000000000a2

PASS=0; FAIL=0; SKIP=0
FAILED_CASES=()

if [ -t 1 ]; then
  G=$'\033[32m'; R=$'\033[31m'; Y=$'\033[33m'; B=$'\033[1m'; N=$'\033[0m'
else
  G=""; R=""; Y=""; B=""; N=""
fi

ok()      { PASS=$((PASS+1)); printf '  %sPASS%s  %s\n' "$G" "$N" "$1"; }
bad()     { FAIL=$((FAIL+1)); FAILED_CASES+=("$1"); printf '  %sFAIL%s  %s\n' "$R" "$N" "$1"
            printf '        expected: %s\n        actual:   %s\n' "$2" "$3"; }

assert_contains() {
  case "$3" in
    *"$2"*) ok "$1" ;;
    *)      bad "$1" "contains '$2'" "$3" ;;
  esac
}
assert_not_contains() {
  case "$3" in
    *"$2"*) bad "$1" "does NOT contain '$2'" "$3" ;;
    *)      ok "$1" ;;
  esac
}
assert_equals() {
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "$2" "$3"; fi
}

# ---------------------------------------------------------------------------
# Config discovery
# ---------------------------------------------------------------------------
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

# login <org> <phone> <pin> -> access_token (empty on failure)
login() {
  local resp
  resp=$(curl -s -X POST "$FUNCTIONS_URL/staff-login" \
    -H "Authorization: Bearer $ANON_KEY" -H 'Content-Type: application/json' \
    -d "{\"organization_id\":\"$1\",\"phone\":\"$2\",\"pin\":\"$3\"}")
  printf '%s' "$resp" | sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p'
}

# rest <token> <path-and-query> -> response body
rest() {
  curl -s "$REST_URL/$2" -H "apikey: $ANON_KEY" -H "Authorization: Bearer $1"
}

# rest_status <token> <path-and-query> -> HTTP status only
rest_status() {
  curl -s -o /dev/null -w '%{http_code}' "$REST_URL/$2" -H "apikey: $ANON_KEY" -H "Authorization: Bearer $1"
}

# count_rows <json-array-body> -> number of elements (crude but dependency-free)
count_rows() {
  local body="$1"
  case "$body" in
    '[]') echo 0 ;;
    '['*']') printf '%s' "$body" | grep -o '"id"' | wc -l | tr -d ' ' ;;
    *) echo -1 ;; # not a JSON array — signals an error body to the caller
  esac
}

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

reset_state() {
  $have_psql || return 0
  docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -q >/dev/null 2>&1 <<SQL
DELETE FROM attendance WHERE member_id = '$MEMBER_LOC2';
DELETE FROM memberships WHERE member_id = '$MEMBER_LOC2';
DELETE FROM members WHERE id = '$MEMBER_LOC2';
DELETE FROM locations WHERE id = '$LOC_IRON_2';
DELETE FROM whatsapp_messages WHERE body_preview IN ('rls-test broadcast', 'rls-test member message');
UPDATE organizations SET gst_number = NULL WHERE id = '$ORG_FLEX';
SQL
}

arrange_fixtures() {
  $have_psql || return 0
  docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -q >/dev/null 2>&1 <<SQL
INSERT INTO locations (id, organization_id, name)
VALUES ('$LOC_IRON_2', '$ORG_IRON', 'Iron Temple — HSR Layout');

INSERT INTO members (id, organization_id, location_id, name, phone, whatsapp_opt_in, source)
VALUES ('$MEMBER_LOC2', '$ORG_IRON', '$LOC_IRON_2', 'Second-Location Test Member', '919000055501', true, 'manual');

UPDATE organizations SET gst_number = '29AAAAA0000A1Z5' WHERE id = '$ORG_IRON';

INSERT INTO whatsapp_messages (organization_id, member_id, direction, template_name, body_preview, status)
VALUES ('$ORG_IRON', NULL, 'outbound', 'daily_owner_brief', 'rls-test broadcast', 'queued');

INSERT INTO whatsapp_messages (organization_id, member_id, direction, template_name, body_preview, status)
VALUES ('$ORG_IRON', 'e2222222-2222-2222-2222-222222222222', 'outbound', 'renewal_reminder', 'rls-test member message', 'queued');
SQL
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

printf '\n%s== RLS + custom access-token hook tests ==%s\n' "$B" "$N"
printf 'target: %s\n' "$BASE_URL"

if [ -z "$ANON_KEY" ]; then
  printf '\n%sERROR%s could not determine the anon key.\n' "$R" "$N"
  printf '        Run `supabase status` from the project root, or export ANON_KEY=...\n\n'
  exit 1
fi

if ! curl -s -o /dev/null --max-time 5 "$FUNCTIONS_URL/staff-login" -X POST -d '{}'; then
  printf '\n%sERROR%s cannot reach staff-login. Start it with:\n' "$R" "$N"
  printf '  supabase functions serve --env-file supabase/functions/.env\n\n'
  exit 1
fi

if ! $have_psql; then
  printf '\n%sERROR%s this suite needs docker/psql for fixture setup (no SKIP path).\n\n' "$R" "$N"
  exit 1
fi

reset_state
arrange_fixtures

printf '\n%s-- minting real sessions via staff-login --%s\n' "$B" "$N"
RAVI=$(login "$ORG_IRON" 919000000001 1234)
PRIYA=$(login "$ORG_IRON" 919000000011 1111)
SANJAY=$(login "$ORG_FLEX" 919000000002 2345)

if [ -z "$RAVI" ] || [ -z "$PRIYA" ] || [ -z "$SANJAY" ]; then
  printf '\n%sERROR%s could not mint one or more sessions — check staff-login / seed.sql.\n\n' "$R" "$N"
  exit 1
fi
ok "minted real sessions for Ravi (Iron owner), Priya (Iron front_desk), Sanjay (FlexFit owner)"

# ---------------------------------------------------------------------------
# 1. Cross-tenant isolation
# ---------------------------------------------------------------------------
printf '\n%s-- cross-tenant isolation --%s\n' "$B" "$N"

got=$(rest "$PRIYA" "members?organization_id=eq.$ORG_FLEX&select=id")
assert_equals "Priya (Iron Temple) reading FlexFit members gets zero rows" "0" "$(count_rows "$got")"

got=$(rest "$SANJAY" "members?organization_id=eq.$ORG_IRON&select=id")
assert_equals "Sanjay (FlexFit) reading Iron Temple members gets zero rows" "0" "$(count_rows "$got")"

got=$(rest "$SANJAY" "payments?organization_id=eq.$ORG_IRON&select=id")
assert_equals "Sanjay reading Iron Temple payments gets zero rows" "0" "$(count_rows "$got")"

# ---------------------------------------------------------------------------
# 2. Location scoping
# ---------------------------------------------------------------------------
printf '\n%s-- location scoping --%s\n' "$B" "$N"

got=$(rest "$PRIYA" "members?organization_id=eq.$ORG_IRON&select=id,location_id")
assert_not_contains "Priya (front_desk @ Indiranagar) does NOT see the HSR Layout member" "$MEMBER_LOC2" "$got"
assert_contains "Priya still sees her own location's real members" "e1111111-1111-1111-1111-111111111111" "$got"

got=$(rest "$RAVI" "members?organization_id=eq.$ORG_IRON&select=id,location_id")
assert_contains "Ravi (owner) DOES see the HSR Layout member" "$MEMBER_LOC2" "$got"
assert_contains "Ravi also sees the Indiranagar members" "e1111111-1111-1111-1111-111111111111" "$got"

got=$(rest "$PRIYA" "locations?select=id")
assert_not_contains "Priya's locations read excludes HSR Layout" "$LOC_IRON_2" "$got"
got=$(rest "$RAVI" "locations?select=id")
assert_contains "Ravi's locations read includes HSR Layout" "$LOC_IRON_2" "$got"

# ---------------------------------------------------------------------------
# 3. Payments — owner-only
# ---------------------------------------------------------------------------
printf '\n%s-- payments: owner-only --%s\n' "$B" "$N"

got=$(rest "$RAVI" "payments?organization_id=eq.$ORG_IRON&select=id")
ravi_payments=$(count_rows "$got")
if [ "$ravi_payments" -gt 0 ] 2>/dev/null; then
  ok "Ravi (owner) sees payment rows ($ravi_payments)"
else
  bad "Ravi (owner) sees payment rows" ">0" "$ravi_payments"
fi
assert_equals "Ravi's payments read is 200, not an error" "200" "$(rest_status "$RAVI" "payments?organization_id=eq.$ORG_IRON&select=id")"

got=$(rest "$PRIYA" "payments?organization_id=eq.$ORG_IRON&select=id")
assert_equals "Priya (front_desk) sees zero payment rows" "0" "$(count_rows "$got")"
assert_equals "Priya's payments read is STILL 200, not 403" "200" "$(rest_status "$PRIYA" "payments?organization_id=eq.$ORG_IRON&select=id")"

# ---------------------------------------------------------------------------
# 4. organizations_for_client — gst_number / owner_phone masking
# ---------------------------------------------------------------------------
printf '\n%s-- organizations_for_client masking --%s\n' "$B" "$N"

got=$(rest "$RAVI" "organizations_for_client?id=eq.$ORG_IRON&select=name,status,owner_phone,gst_number")
assert_contains "Ravi (owner) sees the real gst_number"   "29AAAAA0000A1Z5" "$got"
assert_contains "Ravi (owner) sees the real owner_phone"  "919000000001" "$got"
assert_contains "Ravi still sees name/status"              '"name":"Iron Temple Gym"' "$got"

got=$(rest "$PRIYA" "organizations_for_client?id=eq.$ORG_IRON&select=name,status,owner_phone,gst_number")
assert_contains "Priya (front_desk) sees gst_number masked to null"  '"gst_number":null' "$got"
assert_contains "Priya sees owner_phone masked to null"              '"owner_phone":null' "$got"
assert_contains "Priya still sees name/status (not fully denied)"    '"name":"Iron Temple Gym"' "$got"
assert_not_contains "the real gst_number never appears for Priya"    "29AAAAA0000A1Z5" "$got"

# ---------------------------------------------------------------------------
# 5. whatsapp_messages — broadcast rows are owner-only
# ---------------------------------------------------------------------------
printf '\n%s-- whatsapp_messages: broadcasts are owner-only --%s\n' "$B" "$N"

got=$(rest "$RAVI" "whatsapp_messages?organization_id=eq.$ORG_IRON&select=body_preview")
assert_contains "Ravi sees the org-wide broadcast row"   "rls-test broadcast" "$got"
assert_contains "Ravi sees the member-tied row too"      "rls-test member message" "$got"

got=$(rest "$PRIYA" "whatsapp_messages?organization_id=eq.$ORG_IRON&select=body_preview")
assert_not_contains "Priya does NOT see the org-wide broadcast" "rls-test broadcast" "$got"
assert_contains "Priya DOES see the member-tied message (her location)" "rls-test member message" "$got"

# ---------------------------------------------------------------------------
# 6. anon — zero rows, no error
# ---------------------------------------------------------------------------
printf '\n%s-- anon lockout is zero rows, not an error --%s\n' "$B" "$N"

for table in organizations locations members membership_plans memberships payments attendance whatsapp_messages organizations_for_client; do
  status=$(rest_status "$ANON_KEY" "$table?select=id&limit=1")
  body=$(rest "$ANON_KEY" "$table?select=id&limit=1")
  assert_equals "anon reading $table is 200" "200" "$status"
  assert_equals "anon reading $table returns []" "[]" "$body"
done

# ---------------------------------------------------------------------------
# 7. Tampered JWT — rejected at the gateway, not via RLS
# ---------------------------------------------------------------------------
printf '\n%s-- tampered JWT --%s\n' "$B" "$N"
printf '   (a 401 here proves the request never reached RLS at all — a\n'
printf '    stronger, different guarantee than case 6''s "zero rows")\n'

TAMPERED="${RAVI%?}X"
if [ "$TAMPERED" = "$RAVI" ]; then
  bad "tampering actually changed the token" "a different string" "identical (test bug)"
else
  status=$(rest_status "$TAMPERED" "members?select=id")
  assert_equals "a tampered access_token is rejected 401" "401" "$status"
  body=$(rest "$TAMPERED" "members?select=id")
  assert_contains "the rejection names a JWT/key problem, not a data answer" "PGRST301" "$body"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
reset_state

printf '\n%s== summary ==%s\n' "$B" "$N"
printf '  %spassed %d%s   %sfailed %d%s   %sskipped %d%s\n' "$G" "$PASS" "$N" "$R" "$FAIL" "$N" "$Y" "$SKIP" "$N"

if [ "$FAIL" -gt 0 ]; then
  printf '\n  failing cases:\n'
  for c in "${FAILED_CASES[@]}"; do printf '    - %s\n' "$c"; done
  printf '\n'
  exit 1
fi

printf '\n'
exit 0
