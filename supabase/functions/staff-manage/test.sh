#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Integration tests for the staff-manage Edge Function (owner creates /
# deactivates / reactivates staff in their own org).
#
# No external API. Mints real owner / front_desk sessions via staff-login,
# like staff-pin-reset/test.sh. Creates its own throwaway users so it never
# mutates a seeded staffer.
#
# PREREQUISITES: supabase start; supabase db reset; supabase functions serve
#   --env-file supabase/functions/.env ; then run this file.
# Requires: curl, docker (psql).
# ---------------------------------------------------------------------------

set -uo pipefail

BASE="${BASE_URL:-http://127.0.0.1:54321}"
MANAGE_URL="$BASE/functions/v1/staff-manage"
LOGIN_URL="$BASE/functions/v1/staff-login"
REST_URL="$BASE/rest/v1"
DB_CONTAINER="${DB_CONTAINER:-supabase_db_gym-saas}"
PROJECT_DIR="${PROJECT_DIR:-$(dirname "$0")/../../..}"

ORG_IRON=11111111-1111-1111-1111-111111111111
ORG_FLEX=22222222-2222-2222-2222-222222222222
LOC_IRON=aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa
LOC_FLEX=bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb

# Throwaway rows this suite owns (ids/phones collide with nothing in seed.sql).
NEW_COACH_PHONE=919000078801           # created by the "create" happy path
DEACT_ID=0daded00-8888-0000-0000-000000000001   # pre-inserted, for deactivate/reactivate
DEACT_PHONE=919000078802
DEACT_PIN=3101
DEACT_HASH='$2a$12$0AvZqgUK3y9569oqbJXCX.HeztSPoM2Ef2nJmbVlem4zMmkLfh.K.'  # seed hash for 3101

PASS=0; FAIL=0; SKIP=0
FAILED_CASES=()
if [ -t 1 ]; then G=$'\033[32m'; R=$'\033[31m'; Y=$'\033[33m'; B=$'\033[1m'; N=$'\033[0m'
else G=""; R=""; Y=""; B=""; N=""; fi
ok()  { PASS=$((PASS+1)); printf '  %sPASS%s  %s\n' "$G" "$N" "$1"; }
bad() { FAIL=$((FAIL+1)); FAILED_CASES+=("$1"); printf '  %sFAIL%s  %s\n' "$R" "$N" "$1"
        printf '        expected: %s\n        actual:   %s\n' "$2" "$3"; }
skipped() { SKIP=$((SKIP+1)); printf '  %sSKIP%s  %s\n           %s\n' "$Y" "$N" "$1" "$2"; }
assert_contains() { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "contains '$2'" "$3" ;; esac; }
assert_not_contains() { case "$3" in *"$2"*) bad "$1" "does NOT contain '$2'" "$3" ;; *) ok "$1" ;; esac; }
assert_equals()   { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "$2" "$3"; fi; }

ANON_KEY="${ANON_KEY:-}"
if [ -z "$ANON_KEY" ] && command -v supabase >/dev/null 2>&1; then
  ANON_KEY=$( (cd "$PROJECT_DIR" && supabase status -o env 2>/dev/null) | sed -n 's/^ANON_KEY="\(.*\)"$/\1/p' | tail -1 )
fi
have_psql=false
if docker exec "$DB_CONTAINER" true >/dev/null 2>&1; then have_psql=true; fi
sql() { docker exec "$DB_CONTAINER" psql -U postgres -d postgres -tAc "$1" 2>/dev/null | tr -d '\r'; }

login() {
  curl -s -X POST "$LOGIN_URL" -H "Authorization: Bearer $ANON_KEY" -H 'Content-Type: application/json' \
    -d "{\"organization_id\":\"$1\",\"phone\":\"$2\",\"pin\":\"$3\"}" \
    | sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p'
}
login_status() {
  curl -s -o /dev/null -w '%{http_code}' -X POST "$LOGIN_URL" -H "Authorization: Bearer $ANON_KEY" \
    -H 'Content-Type: application/json' -d "{\"organization_id\":\"$1\",\"phone\":\"$2\",\"pin\":\"$3\"}"
}
login_body() {
  curl -s -X POST "$LOGIN_URL" -H "Authorization: Bearer $ANON_KEY" -H 'Content-Type: application/json' \
    -d "{\"organization_id\":\"$1\",\"phone\":\"$2\",\"pin\":\"$3\"}"
}
manage()        { curl -s -X POST "$MANAGE_URL" -H "Authorization: Bearer $1" -H 'Content-Type: application/json' -d "$2"; }
manage_status() { curl -s -o /dev/null -w '%{http_code}' -X POST "$MANAGE_URL" -H "Authorization: Bearer $1" -H 'Content-Type: application/json' -d "$2"; }

reset_state() {
  $have_psql || return 0
  docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -q >/dev/null 2>&1 <<SQL
DELETE FROM login_attempts WHERE phone IN ('$NEW_COACH_PHONE', '919000078803', '$DEACT_PHONE');
DELETE FROM users WHERE phone IN ('$NEW_COACH_PHONE', '919000078803', '$DEACT_PHONE') OR id = '$DEACT_ID';
DELETE FROM auth.users WHERE email LIKE '0daded00-8888-%@staff.internal.invalid';
-- 2b edits the seeded Iron coach's role only when it has no active packages;
-- the WITH-active-packages case is blocked so Farah is never actually changed.
SQL
}
arrange() {
  $have_psql || return 0
  docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -q >/dev/null 2>&1 <<SQL
INSERT INTO users (id, organization_id, name, phone, role, location_id, pin_hash, active)
VALUES ('$DEACT_ID', '$ORG_IRON', 'Deactivate Target', '$DEACT_PHONE', 'front_desk', '$LOC_IRON', '$DEACT_HASH', true);
SQL
}

printf '\n%s== staff-manage tests ==%s\n' "$B" "$N"
printf 'target: %s\n' "$MANAGE_URL"
if [ -z "$ANON_KEY" ]; then printf '\n%sERROR%s no anon key. Run `supabase status`.\n\n' "$R" "$N"; exit 1; fi
if ! $have_psql; then printf '\n%sERROR%s needs docker/psql.\n\n' "$R" "$N"; exit 1; fi
if ! curl -s -o /dev/null --max-time 5 -X POST "$MANAGE_URL" -d '{}'; then
  printf '\n%sERROR%s cannot reach staff-manage. Start `supabase functions serve`.\n\n' "$R" "$N"; exit 1
fi

reset_state
arrange

RAVI=$(login "$ORG_IRON" 919000000001 1234)     # Iron owner
PRIYA=$(login "$ORG_IRON" 919000000011 1111)    # Iron front_desk
SANJAY=$(login "$ORG_FLEX" 919000000002 2345)   # FlexFit owner
if [ -z "$RAVI" ] || [ -z "$PRIYA" ] || [ -z "$SANJAY" ]; then
  printf '\n%sERROR%s could not mint sessions via staff-login.\n\n' "$R" "$N"; exit 1
fi
ok "minted owner / front_desk / other-org-owner sessions"

# ---------------------------------------------------------------------------
# 0. CORS + input validation
# ---------------------------------------------------------------------------
printf '\n%s-- CORS + input validation --%s\n' "$B" "$N"
pf=$(curl -s -i -X OPTIONS "$MANAGE_URL" -H "Origin: https://app.example.com" -H "Access-Control-Request-Method: POST" | tr '[:upper:]' '[:lower:]')
assert_contains "OPTIONS preflight answered 200" "http/1.1 200" "$pf"
assert_contains "unparseable body -> 400"        '"error":"invalid_json_body"' "$(manage "$RAVI" 'not json')"
assert_contains "unknown action -> 400"          '"error":"action_invalid"' "$(manage "$RAVI" '{"action":"frobnicate"}')"
assert_equals   "GET is rejected"                "405" "$(curl -s -o /dev/null -w '%{http_code}' -X GET "$MANAGE_URL" -H "Authorization: Bearer $RAVI")"

# ---------------------------------------------------------------------------
# 1. Authorization — owner-only, and not "any owner anywhere"
# ---------------------------------------------------------------------------
printf '\n%s-- authorization --%s\n' "$B" "$N"
CREATE_OK="{\"action\":\"create\",\"name\":\"New Coach\",\"phone\":\"$NEW_COACH_PHONE\",\"role\":\"coach\",\"location_id\":\"$LOC_IRON\",\"pin\":\"4455\"}"
assert_equals   "anon key (not a staff session) -> 401"       "401" "$(manage_status "$ANON_KEY" "$CREATE_OK")"
assert_contains "front_desk cannot manage staff -> 403"       '"error":"not_owner"' "$(manage "$PRIYA" "$CREATE_OK")"
DEACT_BODY="{\"action\":\"deactivate\",\"target_user_id\":\"$DEACT_ID\"}"
assert_contains "an owner of ANOTHER org cannot deactivate this org's staff -> 404" \
  '"error":"target_not_found"' "$(manage "$SANJAY" "$DEACT_BODY")"
assert_equals   "  ...404, not 200"                           "404" "$(manage_status "$SANJAY" "$DEACT_BODY")"
assert_equals   "target still active after the cross-org attempt" "t" "$(sql "select active from users where id='$DEACT_ID'")"

# ---------------------------------------------------------------------------
# 2. create — happy path + validation
# ---------------------------------------------------------------------------
printf '\n%s-- create staff --%s\n' "$B" "$N"
got=$(manage "$RAVI" "$CREATE_OK")
assert_contains "owner creates a coach -> ok"                 '"ok":true' "$got"
NEW_ID=$(printf '%s' "$got" | sed -n 's/.*"user_id":"\([^"]*\)".*/\1/p')
assert_equals   "  ...the new coach exists, active, in the owner's org" "coach|true|$ORG_IRON" \
  "$(sql "select role||'|'||active||'|'||organization_id from users where id='$NEW_ID'")"
assert_equals   "  ...the new coach's PIN logs in immediately"  "200" "$(login_status "$ORG_IRON" "$NEW_COACH_PHONE" 4455)"
assert_contains "duplicate phone in the same org -> 409"        '"error":"phone_already_in_org"' \
  "$(manage "$RAVI" "$CREATE_OK")"
assert_contains "invalid role -> 400"    '"error":"role_invalid"' \
  "$(manage "$RAVI" "{\"action\":\"create\",\"name\":\"X\",\"phone\":\"919000078888\",\"role\":\"superuser\",\"pin\":\"1234\"}")"
assert_contains "coach without a location -> 400"  '"error":"location_id_required"' \
  "$(manage "$RAVI" "{\"action\":\"create\",\"name\":\"X\",\"phone\":\"919000078889\",\"role\":\"coach\",\"pin\":\"1234\"}")"
assert_contains "owner WITH a location -> 400"     '"error":"owner_has_no_location"' \
  "$(manage "$RAVI" "{\"action\":\"create\",\"name\":\"X\",\"phone\":\"919000078890\",\"role\":\"owner\",\"location_id\":\"$LOC_IRON\",\"pin\":\"1234\"}")"
assert_contains "location in ANOTHER org -> 400"   '"error":"location_not_in_org"' \
  "$(manage "$RAVI" "{\"action\":\"create\",\"name\":\"X\",\"phone\":\"919000078891\",\"role\":\"coach\",\"location_id\":\"$LOC_FLEX\",\"pin\":\"1234\"}")"

# ---------------------------------------------------------------------------
# 2b. edit — name / phone / role / location_id, never pin_hash
# ---------------------------------------------------------------------------
printf '\n%s-- edit staff --%s\n' "$B" "$N"
FARAH_ID=c0ac0000-0000-0000-0000-000000000001   # seeded Iron coach WITH active packages

assert_contains "edit name -> ok" '"ok":true' \
  "$(manage "$RAVI" "{\"action\":\"edit\",\"target_user_id\":\"$NEW_ID\",\"name\":\"Renamed Coach\"}")"
assert_equals   "  ...name persisted" "Renamed Coach" "$(sql "select name from users where id='$NEW_ID'")"
assert_contains "edit phone -> ok" '"ok":true' \
  "$(manage "$RAVI" "{\"action\":\"edit\",\"target_user_id\":\"$NEW_ID\",\"phone\":\"919000078803\"}")"
assert_equals   "  ...phone persisted" "919000078803" "$(sql "select phone from users where id='$NEW_ID'")"
assert_contains "edit with an empty payload -> 400" '"error":"no_editable_fields"' \
  "$(manage "$RAVI" "{\"action\":\"edit\",\"target_user_id\":\"$NEW_ID\"}")"
assert_contains "edit location to another org -> 400" '"error":"location_not_in_org"' \
  "$(manage "$RAVI" "{\"action\":\"edit\",\"target_user_id\":\"$NEW_ID\",\"location_id\":\"$LOC_FLEX\"}")"
assert_contains "an owner of ANOTHER org cannot edit this org's staff -> 404" '"error":"target_not_found"' \
  "$(manage "$SANJAY" "{\"action\":\"edit\",\"target_user_id\":\"$NEW_ID\",\"name\":\"Hijack\"}")"

# pin_hash / pin in the payload are ignored, never written.
OLD_HASH=$(sql "select pin_hash from users where id='$DEACT_ID'")
assert_contains "edit ignoring a pin_hash in the payload -> ok" '"ok":true' \
  "$(manage "$RAVI" "{\"action\":\"edit\",\"target_user_id\":\"$DEACT_ID\",\"name\":\"Still 3101\",\"pin_hash\":\"\$2a\$12\$totallyfakehashvaluethatmustneverbestored000000000000\",\"pin\":\"9999\"}")"
assert_equals   "  ...name changed"              "Still 3101" "$(sql "select name from users where id='$DEACT_ID'")"
assert_equals   "  ...pin_hash UNCHANGED"        "$OLD_HASH" "$(sql "select pin_hash from users where id='$DEACT_ID'")"
assert_equals   "  ...original PIN 3101 still logs in" "200" "$(login_status "$ORG_IRON" "$DEACT_PHONE" 3101)"

# role change coach -> front_desk, NO active packages: allowed.
assert_contains "coach -> front_desk (no active packages) -> ok" '"ok":true' \
  "$(manage "$RAVI" "{\"action\":\"edit\",\"target_user_id\":\"$NEW_ID\",\"role\":\"front_desk\",\"location_id\":\"$LOC_IRON\"}")"
assert_equals   "  ...role persisted" "front_desk" "$(sql "select role from users where id='$NEW_ID'")"
# put it back so section 6 (coaches_directory) still has a coach to test with
manage "$RAVI" "{\"action\":\"edit\",\"target_user_id\":\"$NEW_ID\",\"role\":\"coach\",\"location_id\":\"$LOC_IRON\"}" >/dev/null

# role change coach -> front_desk WITH active packages: blocked.
got=$(manage "$RAVI" "{\"action\":\"edit\",\"target_user_id\":\"$FARAH_ID\",\"role\":\"front_desk\",\"location_id\":\"$LOC_IRON\"}")
assert_contains "coach -> front_desk WITH active packages -> 409" '"error":"coach_has_active_packages"' "$got"
assert_contains "  ...reports the count"        '"active_package_count":' "$got"
assert_equals   "  ...Farah is still a coach"   "coach" "$(sql "select role from users where id='$FARAH_ID'")"

# ---------------------------------------------------------------------------
# 3. deactivate — the actual "revoke access" mechanism
# ---------------------------------------------------------------------------
printf '\n%s-- deactivate revokes access --%s\n' "$B" "$N"
assert_equals   "target can log in BEFORE deactivation"     "200" "$(login_status "$ORG_IRON" "$DEACT_PHONE" "$DEACT_PIN")"
got=$(manage "$RAVI" "$DEACT_BODY")
assert_contains "owner deactivates a same-org staffer -> ok" '"ok":true' "$got"
assert_contains "  ...reports the action"                    '"action":"deactivate"' "$got"
assert_equals   "  ...users.active is now false"             "f" "$(sql "select active from users where id='$DEACT_ID'")"
resp=$(login_body "$ORG_IRON" "$DEACT_PHONE" "$DEACT_PIN")
assert_contains "a DEACTIVATED user with the CORRECT PIN cannot log in" '"error":"account_deactivated"' "$resp"
assert_equals   "  ...403, not 200"                          "403" "$(login_status "$ORG_IRON" "$DEACT_PHONE" "$DEACT_PIN")"
assert_contains "a deactivated user with a WRONG PIN still gets the generic error" '"error":"invalid_credentials"' \
  "$(login_body "$ORG_IRON" "$DEACT_PHONE" 9999)"

# ---------------------------------------------------------------------------
# 4. reactivate — access comes back
# ---------------------------------------------------------------------------
printf '\n%s-- reactivate --%s\n' "$B" "$N"
got=$(manage "$RAVI" "{\"action\":\"reactivate\",\"target_user_id\":\"$DEACT_ID\"}")
assert_contains "owner reactivates -> ok"          '"ok":true' "$got"
assert_equals   "  ...users.active is true again"  "t" "$(sql "select active from users where id='$DEACT_ID'")"
assert_equals   "  ...the staffer can log in again with the correct PIN" "200" \
  "$(login_status "$ORG_IRON" "$DEACT_PHONE" "$DEACT_PIN")"

# ---------------------------------------------------------------------------
# 5. self-deactivation is blocked
# ---------------------------------------------------------------------------
printf '\n%s-- an owner cannot deactivate themselves --%s\n' "$B" "$N"
RAVI_ID=$(sql "select id from users where organization_id='$ORG_IRON' and phone='919000000001'")
assert_contains "owner deactivating own id -> 400" '"error":"cannot_deactivate_self"' \
  "$(manage "$RAVI" "{\"action\":\"deactivate\",\"target_user_id\":\"$RAVI_ID\"}")"
assert_equals   "  ...owner still active"          "t" "$(sql "select active from users where id='$RAVI_ID'")"

# ---------------------------------------------------------------------------
# 6. a deactivated coach drops out of coaches_directory (assign dropdown)
# ---------------------------------------------------------------------------
printf '\n%s-- deactivated coach not assignable --%s\n' "$B" "$N"
dir_before=$(curl -s "$REST_URL/coaches_directory?select=id" -H "apikey: $ANON_KEY" -H "Authorization: Bearer $RAVI")
case "$dir_before" in *"$NEW_ID"*) ok "the new active coach IS in coaches_directory" ;; *) bad "new coach in coaches_directory" "contains $NEW_ID" "$dir_before" ;; esac
manage "$RAVI" "{\"action\":\"deactivate\",\"target_user_id\":\"$NEW_ID\"}" >/dev/null
dir_after=$(curl -s "$REST_URL/coaches_directory?select=id" -H "apikey: $ANON_KEY" -H "Authorization: Bearer $RAVI")
assert_not_contains "a DEACTIVATED coach is gone from coaches_directory" "$NEW_ID" "$dir_after"
# staff_directory (owner) still shows them, with active=false, so "show inactive" works
staff_dir=$(curl -s "$REST_URL/staff_directory?select=id,active&id=eq.$NEW_ID" -H "apikey: $ANON_KEY" -H "Authorization: Bearer $RAVI")
assert_contains "staff_directory still lists the deactivated coach" "$NEW_ID" "$staff_dir"
assert_contains "  ...flagged active:false"  '"active":false' "$staff_dir"

# ---------------------------------------------------------------------------
reset_state

printf '\n%s== summary ==%s\n' "$B" "$N"
printf '  %spassed %d%s   %sfailed %d%s   %sskipped %d%s\n' "$G" "$PASS" "$N" "$R" "$FAIL" "$N" "$Y" "$SKIP" "$N"
if [ "$FAIL" -gt 0 ]; then
  printf '\n  failing cases:\n'; for c in "${FAILED_CASES[@]}"; do printf '    - %s\n' "$c"; done
  printf '\n'; exit 1
fi
printf '\n'; exit 0
