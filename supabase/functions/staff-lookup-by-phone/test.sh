#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Integration tests for the staff-lookup-by-phone Edge Function.
#
# No external API is called and no rate limiting exists here (see index.ts's
# own note on why) — this suite is safe to run repeatedly and costs nothing.
#
# PREREQUISITES
#   1. supabase start
#   2. supabase db reset                 # applies migrations + seed.sql
#   3. supabase functions serve --env-file supabase/functions/.env
#   4. bash supabase/functions/staff-lookup-by-phone/test.sh
#
# Requires: curl, docker (for the 2-org fixture — no seeded phone exists at
# two different orgs today, so this suite creates and removes one itself).
# ---------------------------------------------------------------------------

set -uo pipefail

BASE_URL="${BASE_URL:-http://127.0.0.1:54321/functions/v1/staff-lookup-by-phone}"
DB_CONTAINER="${DB_CONTAINER:-supabase_db_gym-saas}"
PROJECT_DIR="${PROJECT_DIR:-$(dirname "$0")/../../..}"

# Seeded fixtures (see supabase/seed.sql)
ORG_IRON=11111111-1111-1111-1111-111111111111
ORG_FLEX=22222222-2222-2222-2222-222222222222
PHONE_ONE_MATCH=919000000001     # Ravi Krishnan, owner, Iron Temple only
PHONE_NO_MATCH=919000088801      # correctly formatted, no such user anywhere

# NOT 919000000011 (Priya): staff-login/test.sh's own "same phone, different
# org" case deliberately leaves a throwaway fixture user permanently
# recreated at that exact phone number every time IT resets — see that
# suite's reset_state(). Since run-all-tests.sh runs staff-login right before
# this suite, that fixture is still present when this one starts, so a
# "single match" phone here has to be one nothing else in the project ever
# attaches a second fixture row to.

# Throwaway fixture: the SAME phone as a real staff member at TWO different
# orgs — nothing in seed.sql has this today (checked: every seeded phone maps
# to exactly one org). Created by arrange_fixtures(), removed by reset_state().
PHONE_TWO_MATCH=919000099901
TWO_MATCH_USER_IRON=0daded00-2222-0000-0000-000000000001
TWO_MATCH_USER_FLEX=0daded00-2222-0000-0000-000000000002

PASS=0; FAIL=0; SKIP=0
FAILED_CASES=()

if [ -t 1 ]; then
  G=$'\033[32m'; R=$'\033[31m'; Y=$'\033[33m'; B=$'\033[1m'; N=$'\033[0m'
else
  G=""; R=""; Y=""; B=""; N=""
fi

ANON_KEY="${ANON_KEY:-}"
if [ -z "$ANON_KEY" ] && command -v supabase >/dev/null 2>&1; then
  ANON_KEY=$( (cd "$PROJECT_DIR" && supabase status -o env 2>/dev/null) \
    | sed -n 's/^ANON_KEY="\(.*\)"$/\1/p' | tail -1 )
fi

have_psql=false
if docker exec "$DB_CONTAINER" true >/dev/null 2>&1; then have_psql=true; fi

# ---------------------------------------------------------------------------
# Assertions
# ---------------------------------------------------------------------------

ok()      { PASS=$((PASS+1)); printf '  %sPASS%s  %s\n' "$G" "$N" "$1"; }
bad()     { FAIL=$((FAIL+1)); FAILED_CASES+=("$1"); printf '  %sFAIL%s  %s\n' "$R" "$N" "$1"
            printf '        expected: %s\n        actual:   %s\n' "$2" "$3"; }
skipped() { SKIP=$((SKIP+1)); printf '  %sSKIP%s  %s\n           %s\n' "$Y" "$N" "$1" "$2"; }

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
# Transport
# ---------------------------------------------------------------------------

post() { # <phone-or-RAW:body> -> response body
  local payload="$1" body
  case "$payload" in
    RAW:*) body="${payload#RAW:}" ;;
    *)     body="{\"phone\":\"$payload\"}" ;;
  esac
  curl -s -X POST "$BASE_URL" -H "Authorization: Bearer $ANON_KEY" -H 'Content-Type: application/json' -d "$body"
}

post_status() {
  local payload="$1" body
  case "$payload" in
    RAW:*) body="${payload#RAW:}" ;;
    *)     body="{\"phone\":\"$payload\"}" ;;
  esac
  curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE_URL" -H "Authorization: Bearer $ANON_KEY" -H 'Content-Type: application/json' -d "$body"
}

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

reset_state() {
  $have_psql || return 0
  docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -q >/dev/null 2>&1 <<SQL
DELETE FROM users WHERE id IN ('$TWO_MATCH_USER_IRON', '$TWO_MATCH_USER_FLEX');
SQL
}

arrange_two_match_fixture() {
  $have_psql || return 0
  docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -q >/dev/null 2>&1 <<SQL
INSERT INTO users (id, organization_id, name, phone, role)
VALUES
  ('$TWO_MATCH_USER_IRON', '$ORG_IRON', 'Two-Org Fixture (Iron)', '$PHONE_TWO_MATCH', 'front_desk'),
  ('$TWO_MATCH_USER_FLEX', '$ORG_FLEX', 'Two-Org Fixture (FlexFit)', '$PHONE_TWO_MATCH', 'owner');
SQL
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

printf '\n%s== staff-lookup-by-phone tests ==%s\n' "$B" "$N"
printf 'target: %s\n' "$BASE_URL"

if [ -z "$ANON_KEY" ]; then
  printf '\n%sERROR%s could not determine the anon key.\n' "$R" "$N"
  printf '        Run `supabase status` from the project root, or export ANON_KEY=...\n\n'
  exit 1
fi

if ! curl -s -o /dev/null --max-time 5 -X POST "$BASE_URL" -d '{}'; then
  printf '\n%sERROR%s cannot reach the function. Start it with:\n' "$R" "$N"
  printf '  supabase functions serve --env-file supabase/functions/.env\n\n'
  exit 1
fi

if $have_psql; then
  if [ "$(docker exec "$DB_CONTAINER" psql -U postgres -d postgres -tAc "select count(*) from users where phone='$PHONE_ONE_MATCH';" 2>/dev/null)" != "1" ]; then
    printf '\n%sERROR%s user fixtures missing. Run: supabase db reset\n\n' "$R" "$N"
    exit 1
  fi
else
  printf '%swarn%s  docker/psql unavailable — the 2-org case will SKIP\n' "$Y" "$N"
fi

reset_state

# ---------------------------------------------------------------------------
# 0. CORS preflight — see staff-login/test.sh's identical section for why
# this exists and why local Kong answering it doesn't fully prove the
# function's own OPTIONS handler works (point BASE_URL at a real deployed
# URL to actually exercise that).
# ---------------------------------------------------------------------------
printf '\n%s-- CORS preflight --%s\n' "$B" "$N"

preflight=$(curl -s -i -X OPTIONS "$BASE_URL" \
  -H "Origin: https://example-frontend.vercel.app" \
  -H "Access-Control-Request-Method: POST" \
  -H "Access-Control-Request-Headers: authorization,content-type" \
  | tr '[:upper:]' '[:lower:]')
assert_contains "OPTIONS preflight is answered 200"           "http/1.1 200" "$preflight"
assert_contains "preflight allows the calling origin"         "access-control-allow-origin:" "$preflight"
assert_contains "preflight allows authorization/content-type" "access-control-allow-headers:" "$preflight"
assert_contains "preflight names POST as an allowed method"   "access-control-allow-methods:" "$preflight"

# ---------------------------------------------------------------------------
# 1. Input validation
# ---------------------------------------------------------------------------
printf '\n%s-- input validation --%s\n' "$B" "$N"

assert_contains "unparseable body is a clear 400" '"error":"invalid_json_body"' "$(post 'RAW:not json')"
assert_contains "missing phone is a clear 400" '"error":"phone_required"' "$(post 'RAW:{}')"
assert_contains "garbage (non-digit) phone is a clear 400" '"error":"phone_malformed"' "$(post 'abc')"
assert_contains "too-short digit string is a clear 400" '"error":"phone_malformed"' "$(post '123')"

got=$(curl -s -X GET "$BASE_URL" -H "Authorization: Bearer $ANON_KEY")
assert_contains "GET is rejected (this endpoint is POST-only)" 'method_not_allowed' "$got"

# ---------------------------------------------------------------------------
# 2. Zero matches
# ---------------------------------------------------------------------------
printf '\n%s-- zero matches --%s\n' "$B" "$N"

got=$(post "$PHONE_NO_MATCH")
assert_contains "unregistered phone returns not_found" '"error":"not_found"' "$got"
assert_equals   "unregistered phone returns 404"       "404" "$(post_status "$PHONE_NO_MATCH")"
assert_not_contains "zero-match response has no organization_id" 'organization_id' "$got"

# ---------------------------------------------------------------------------
# 3. Exactly one match
# ---------------------------------------------------------------------------
printf '\n%s-- exactly one match --%s\n' "$B" "$N"

got=$(post "$PHONE_ONE_MATCH")
assert_contains "single match is ok:true"              '"ok":true' "$got"
assert_contains "single match returns organization_id"  "\"organization_id\":\"$ORG_IRON\"" "$got"
assert_contains "single match returns organization_name" '"organization_name":"Iron Temple Gym"' "$got"
assert_contains "single match returns the staff name"    '"name":"Ravi Krishnan"' "$got"
assert_contains "single match returns the role"          '"role":"owner"' "$got"
assert_not_contains "single-match response is not a list" '"matches"' "$got"
assert_equals   "single match returns 200"               "200" "$(post_status "$PHONE_ONE_MATCH")"

# ---------------------------------------------------------------------------
# 4. Two-plus matches (same phone, different orgs)
# ---------------------------------------------------------------------------
printf '\n%s-- two-plus matches --%s\n' "$B" "$N"

if ! $have_psql; then
  skipped "phone at two different orgs returns a match list" "requires docker/psql to create the fixture"
else
  arrange_two_match_fixture

  got=$(post "$PHONE_TWO_MATCH")
  assert_contains "two-org phone is ok:true"          '"ok":true' "$got"
  assert_contains "response is a matches list"        '"matches":[' "$got"
  assert_contains "Iron Temple match is present"      "\"organization_id\":\"$ORG_IRON\"" "$got"
  assert_contains "FlexFit match is present"          "\"organization_id\":\"$ORG_FLEX\"" "$got"
  assert_contains "Iron Temple fixture name present"  'Two-Org Fixture (Iron)' "$got"
  assert_contains "FlexFit fixture name present"      'Two-Org Fixture (FlexFit)' "$got"
  assert_contains "Iron Temple fixture role present"  '"role":"front_desk"' "$got"
  assert_contains "FlexFit fixture role present"      '"role":"owner"' "$got"
  assert_equals   "two-org phone returns 200"         "200" "$(post_status "$PHONE_TWO_MATCH")"

  reset_state
fi

# ---------------------------------------------------------------------------
# 4b. Suspended org — a suspended gym's staff are invisible to the pre-PIN
#     lookup (org-status enforcement 20260902090000). Apex Strength Co is
#     seeded status='suspended'; Nisha Raman (919100000001) is ONLY at Apex.
# ---------------------------------------------------------------------------
printf '\n%s-- suspended org is hidden --%s\n' "$B" "$N"
got=$(post 919100000001)
assert_contains "phone only at a SUSPENDED org -> org_suspended" '"error":"org_suspended"' "$got"
assert_equals   "  ...403, not 200"                              "403" "$(post_status 919100000001)"
assert_not_contains "  ...no organization_id is leaked"          '"organization_id"' "$got"

# ---------------------------------------------------------------------------
# 5. pin_hash must NEVER appear in any response — grepped, not assumed
# ---------------------------------------------------------------------------
printf '\n%s-- pin_hash never leaks --%s\n' "$B" "$N"

ALL_RESPONSES=""
ALL_RESPONSES+="$(post 'RAW:{}')"
ALL_RESPONSES+="$(post 'abc')"
ALL_RESPONSES+="$(post "$PHONE_NO_MATCH")"
ALL_RESPONSES+="$(post "$PHONE_ONE_MATCH")"
if $have_psql; then
  arrange_two_match_fixture
  ALL_RESPONSES+="$(post "$PHONE_TWO_MATCH")"
  reset_state
fi

assert_not_contains "pin_hash never appears in any response body" 'pin_hash' "$ALL_RESPONSES"
# bcrypt hashes are unmistakable ($2a$ / $2b$ prefix) — grep for the SHAPE too,
# not just the literal column name, in case a future refactor selects the
# column under a different alias.
assert_not_contains "no bcrypt-shaped hash ('\$2a\$' or '\$2b\$') ever appears" '$2a$' "$ALL_RESPONSES"
assert_not_contains "no bcrypt-shaped hash (\$2b\$ variant) ever appears" '$2b$' "$ALL_RESPONSES"

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
