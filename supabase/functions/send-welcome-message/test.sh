#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Integration tests for send-welcome-message.
#
# The welcome_message Meta template is NOT approved yet, so every send here is
# in TEMPORARY SEND MODE: the function writes the whatsapp_messages audit row
# (status 'queued', template_name 'welcome_message') and makes NO Meta call.
# That is what these tests assert. WHATSAPP_SEND_MODE=mock is still required
# (shared guard) even though this function never reaches the shared sender
# while the template is unapproved.
#
# PREREQUISITES: supabase start; supabase db reset; supabase functions serve
#   --env-file supabase/functions/.env ; then run this file.
# Requires: curl, docker (psql).
# ---------------------------------------------------------------------------

set -uo pipefail

BASE="${BASE_URL:-http://127.0.0.1:54321}"
WELCOME_URL="$BASE/functions/v1/send-welcome-message"
LOGIN_URL="$BASE/functions/v1/staff-login"
DB_CONTAINER="${DB_CONTAINER:-supabase_db_gym-saas}"
PROJECT_DIR="${PROJECT_DIR:-$(dirname "$0")/../../..}"
ENV_FILE="${ENV_FILE:-$(dirname "$0")/../.env}"

ORG_IRON=11111111-1111-1111-1111-111111111111
ORG_FLEX=22222222-2222-2222-2222-222222222222
LOC_IRON=aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa
LOC_FLEX=bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb

# Throwaway members this suite owns.
M_OPTIN=de1e7e00-0000-0000-0000-0000000000a1     # Iron, opted IN
M_OPTOUT=de1e7e00-0000-0000-0000-0000000000a2    # Iron, opted OUT
M_FLEX=de1e7e00-0000-0000-0000-0000000000b1      # FlexFit, opted IN (suspended-org case)

PASS=0; FAIL=0; SKIP=0
FAILED_CASES=()
if [ -t 1 ]; then G=$'\033[32m'; R=$'\033[31m'; Y=$'\033[33m'; B=$'\033[1m'; N=$'\033[0m'
else G=""; R=""; Y=""; B=""; N=""; fi
ok()  { PASS=$((PASS+1)); printf '  %sPASS%s  %s\n' "$G" "$N" "$1"; }
bad() { FAIL=$((FAIL+1)); FAILED_CASES+=("$1"); printf '  %sFAIL%s  %s\n' "$R" "$N" "$1"
        printf '        expected: %s\n        actual:   %s\n' "$2" "$3"; }
assert_contains()     { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "contains '$2'" "$3" ;; esac; }
assert_not_contains() { case "$3" in *"$2"*) bad "$1" "does NOT contain '$2'" "$3" ;; *) ok "$1" ;; esac; }
assert_equals()       { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "$2" "$3"; fi; }

read_env() { [ -f "$ENV_FILE" ] || return 0; sed -n "s/^[[:space:]]*$1=//p" "$ENV_FILE" | tail -1 | tr -d '\r"'; }
WA_SEND_MODE="${WHATSAPP_SEND_MODE:-$(read_env WHATSAPP_SEND_MODE)}"

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
welcome()        { curl -s -X POST "$WELCOME_URL" -H "Authorization: Bearer $1" -H 'Content-Type: application/json' -d "$2"; }
welcome_status() { curl -s -o /dev/null -w '%{http_code}' -X POST "$WELCOME_URL" -H "Authorization: Bearer $1" -H 'Content-Type: application/json' -d "$2"; }

reset_state() {
  $have_psql || return 0
  docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -q >/dev/null 2>&1 <<SQL
UPDATE organizations SET status='active' WHERE id IN ('$ORG_IRON','$ORG_FLEX');
DELETE FROM whatsapp_messages WHERE member_id IN ('$M_OPTIN','$M_OPTOUT','$M_FLEX');
DELETE FROM members WHERE id IN ('$M_OPTIN','$M_OPTOUT','$M_FLEX');
SQL
}
arrange() {
  $have_psql || return 0
  docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -q >/dev/null 2>&1 <<SQL
INSERT INTO members (id, organization_id, location_id, name, phone, whatsapp_opt_in) VALUES
  ('$M_OPTIN',  '$ORG_IRON', '$LOC_IRON', 'Welcome OptIn',  '919000091001', true),
  ('$M_OPTOUT', '$ORG_IRON', '$LOC_IRON', 'Welcome OptOut', '919000091002', false),
  ('$M_FLEX',   '$ORG_FLEX', '$LOC_FLEX', 'Welcome Flex',   '919000091003', true);
SQL
}

printf '\n%s== send-welcome-message tests ==%s\n' "$B" "$N"
printf 'target: %s\n' "$WELCOME_URL"
if [ "$(printf '%s' "$WA_SEND_MODE" | tr '[:upper:]' '[:lower:]')" != "mock" ]; then
  printf '\n%sREFUSING TO RUN%s WHATSAPP_SEND_MODE is not "mock" (got: %s).\n\n' "$R" "$N" "${WA_SEND_MODE:-<unset>}"; exit 1
fi
if [ -z "$ANON_KEY" ]; then printf '\n%sERROR%s no anon key.\n\n' "$R" "$N"; exit 1; fi
if ! $have_psql; then printf '\n%sERROR%s needs docker/psql.\n\n' "$R" "$N"; exit 1; fi
if ! curl -s -o /dev/null --max-time 5 -X POST "$WELCOME_URL" -d '{}'; then
  printf '\n%sERROR%s cannot reach send-welcome-message.\n\n' "$R" "$N"; exit 1
fi

reset_state
arrange

RAVI=$(login "$ORG_IRON" 919000000001 1234)     # Iron owner
PRIYA=$(login "$ORG_IRON" 919000000011 1111)    # Iron front_desk
FARAH=$(login "$ORG_IRON" 918454000001 1234)    # Iron coach
SANJAY=$(login "$ORG_FLEX" 919000000002 2345)   # FlexFit owner
if [ -z "$RAVI" ] || [ -z "$PRIYA" ] || [ -z "$FARAH" ] || [ -z "$SANJAY" ]; then
  printf '\n%sERROR%s could not mint staff sessions.\n\n' "$R" "$N"; exit 1
fi
ok "minted owner / front_desk / coach / other-org-owner sessions"

# ---------------------------------------------------------------------------
printf '\n%s-- CORS + method + input --%s\n' "$B" "$N"
pf=$(curl -s -i -X OPTIONS "$WELCOME_URL" -H "Origin: https://app.example.com" -H "Access-Control-Request-Method: POST" | tr '[:upper:]' '[:lower:]')
assert_contains "OPTIONS preflight -> 200"       "http/1.1 200" "$pf"
assert_equals   "GET -> 405"                     "405" "$(curl -s -o /dev/null -w '%{http_code}' -X GET "$WELCOME_URL" -H "Authorization: Bearer $RAVI")"
assert_contains "malformed member_id -> 400"     '"error":"member_id_malformed"' "$(welcome "$RAVI" '{"member_id":"nope"}')"

printf '\n%s-- authorization --%s\n' "$B" "$N"
assert_equals   "anon key (not a staff session) -> 401" "401" "$(welcome_status "$ANON_KEY" "{\"member_id\":\"$M_OPTIN\"}")"
assert_contains "a coach cannot send welcomes -> 403"   '"error":"not_authorized"' "$(welcome "$FARAH" "{\"member_id\":\"$M_OPTIN\"}")"
assert_contains "member in ANOTHER org -> 404"          '"error":"member_not_found"' "$(welcome "$SANJAY" "{\"member_id\":\"$M_OPTIN\"}")"

printf '\n%s-- happy path (temporary send mode) --%s\n' "$B" "$N"
got=$(welcome "$RAVI" "{\"member_id\":\"$M_OPTIN\"}")
assert_contains "opted-in member at an active org -> ok"      '"ok":true' "$got"
assert_contains "  ...simulated (template pending approval)"  '"simulated":true' "$got"
assert_contains "  ...reason is template_pending_approval"    '"reason":"template_pending_approval"' "$got"
row=$(sql "select status||'|'||template_name||'|'||left(body_preview,22) from whatsapp_messages where member_id='$M_OPTIN' order by created_at desc limit 1")
assert_equals   "  ...one queued welcome_message audit row"   "queued|welcome_message|Welcome to Iron Temple" "$row"
assert_equals   "  ...no Meta id (nothing was sent)"          "" "$(sql "select coalesce(wa_message_id::text,'') from whatsapp_messages where member_id='$M_OPTIN' order by created_at desc limit 1")"

printf '\n%s-- idempotency + skip paths --%s\n' "$B" "$N"
assert_contains "second call for the same member -> skipped:already_sent" '"skipped":"already_sent"' \
  "$(welcome "$RAVI" "{\"member_id\":\"$M_OPTIN\"}")"
assert_equals   "  ...still exactly one row"  "1" "$(sql "select count(*) from whatsapp_messages where member_id='$M_OPTIN'")"

got=$(welcome "$PRIYA" "{\"member_id\":\"$M_OPTOUT\"}")
assert_contains "opted-OUT member -> skipped:opted_out (front_desk caller)" '"skipped":"opted_out"' "$got"
assert_equals   "  ...no row written"  "0" "$(sql "select count(*) from whatsapp_messages where member_id='$M_OPTOUT'")"

printf '\n%s-- suspended org --%s\n' "$B" "$N"
sql "update organizations set status='suspended' where id='$ORG_FLEX'" >/dev/null
got=$(welcome "$SANJAY" "{\"member_id\":\"$M_FLEX\"}")
assert_contains "suspended org -> skipped:org_suspended" '"skipped":"org_suspended"' "$got"
assert_equals   "  ...no row written"  "0" "$(sql "select count(*) from whatsapp_messages where member_id='$M_FLEX'")"
sql "update organizations set status='active' where id='$ORG_FLEX'" >/dev/null
assert_contains "  ...after reactivation the welcome sends" '"simulated":true' \
  "$(welcome "$SANJAY" "{\"member_id\":\"$M_FLEX\"}")"

# ---------------------------------------------------------------------------
reset_state
printf '\n%s== summary ==%s\n' "$B" "$N"
printf '  %spassed %d%s   %sfailed %d%s   %sskipped %d%s\n' "$G" "$PASS" "$N" "$R" "$FAIL" "$N" "$Y" "$SKIP" "$N"
if [ "$FAIL" -gt 0 ]; then
  printf '\n  failing cases:\n'; for c in "${FAILED_CASES[@]}"; do printf '    - %s\n' "$c"; done
  printf '\n'; exit 1
fi
printf '\n'; exit 0
