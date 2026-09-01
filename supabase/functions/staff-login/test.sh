#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Integration tests for the staff-login Edge Function.
#
# Asserts PASS/FAIL on the HTTP response shape AND the resulting database
# state, same pattern as the other suites. No external API is called (Meta,
# Razorpay) — the only "external" surface here is this project's own local
# GoTrue (auth.users), which the Admin API calls hit for real.
#
# PREREQUISITES
#   1. supabase start
#   2. supabase db reset                 # applies migrations + seed.sql
#   3. supabase functions serve --env-file supabase/functions/.env
#   4. bash supabase/functions/staff-login/test.sh
#
# Requires: curl, docker (for DB assertions and fixture setup — several cases
# below are DB-only, not degrade-to-SKIP, because there is no way to test
# "lockout expires after 15 minutes" without backdating rows).
# ---------------------------------------------------------------------------

set -uo pipefail

BASE_URL="${BASE_URL:-http://127.0.0.1:54321/functions/v1/staff-login}"
DB_CONTAINER="${DB_CONTAINER:-supabase_db_gym-saas}"
PROJECT_DIR="${PROJECT_DIR:-$(dirname "$0")/../../..}"

# Seeded fixtures (see supabase/seed.sql)
ORG_IRON=11111111-1111-1111-1111-111111111111
ORG_FLEX=22222222-2222-2222-2222-222222222222

USER_PRIYA=92222222-2222-2222-2222-222222222222   # Iron Temple front_desk
PHONE_PRIYA=919000000011
PIN_PRIYA=1111

USER_RAVI=91111111-1111-1111-1111-111111111111    # Iron Temple owner
PHONE_RAVI=919000000001
PIN_RAVI=1234

PHONE_NONEXISTENT=919000099999   # correctly formatted, no such user at ORG_IRON

# Throwaway fixture: a SECOND real user at FlexFit whose phone happens to
# equal Priya's (Iron Temple). Proves organization_id is actually checked,
# not just phone — cleaned up and recreated fresh by reset_state().
CROSS_ORG_USER=9eeeeeee-eeee-eeee-eeee-eeeeeeeeeeee
CROSS_ORG_PIN=2222
CROSS_ORG_PIN_HASH='$2a$12$P2guAJ41at5K/RCytsI8zevhRcAEX/3S0n0xfbWPqGBqY6zU21HOi' # same hash as Divya's (pin 2222) — reusing a hash string across rows is fine, bcrypt's salt lives inside it

PASS=0; FAIL=0; SKIP=0
FAILED_CASES=()

if [ -t 1 ]; then
  G=$'\033[32m'; R=$'\033[31m'; Y=$'\033[33m'; B=$'\033[1m'; N=$'\033[0m'
else
  G=""; R=""; Y=""; B=""; N=""
fi

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

# post <organization_id> <phone> <pin> -> response body
post() {
  local body
  body=$(printf '{"organization_id":"%s","phone":"%s","pin":"%s"}' "$1" "$2" "$3")
  curl -s -X POST "$BASE_URL" \
    -H "Authorization: Bearer $ANON_KEY" -H 'Content-Type: application/json' \
    -d "$body"
}

post_status() {
  local body
  body=$(printf '{"organization_id":"%s","phone":"%s","pin":"%s"}' "$1" "$2" "$3")
  curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE_URL" \
    -H "Authorization: Bearer $ANON_KEY" -H 'Content-Type: application/json' \
    -d "$body"
}

# post_raw <raw-json-body> -> response body — for malformed-input cases
post_raw() {
  curl -s -X POST "$BASE_URL" \
    -H "Authorization: Bearer $ANON_KEY" -H 'Content-Type: application/json' \
    -d "$1"
}

field() { printf '%s' "$2" | sed -n "s/.*\"$1\":\"\([^\"]*\)\".*/\1/p" | head -1; }
field_num() { printf '%s' "$2" | sed -n "s/.*\"$1\":\([0-9-]*\).*/\1/p" | head -1; }

# ---------------------------------------------------------------------------
# Database helpers
# ---------------------------------------------------------------------------

sql() { docker exec "$DB_CONTAINER" psql -U postgres -d postgres -tAc "$1" 2>/dev/null | tr -d '\r'; }

assert_db() {
  if ! $have_psql; then
    skipped "$1" "docker/psql unavailable (container '$DB_CONTAINER')"
    return
  fi
  assert_equals "$1" "$2" "$3"
}

# Backdate N failed attempts for (org,phone), the oldest `minutes_ago_start +
# N-1` minutes back and the newest `minutes_ago_start` minutes back — same
# trick as daily-owner-brief/test.sh's arrange_failed_sends(), applied to
# login_attempts instead of whatsapp_messages.
arrange_failed_attempts() { # <org> <phone> <count> <minutes_ago_of_newest>
  $have_psql || return 0
  local org="$1" phone="$2" count="$3" start="$4" stmts=""
  for i in $(seq 1 "$count"); do
    stmts+="INSERT INTO login_attempts (organization_id, phone, attempted_at, success)
             VALUES ('$org','$phone', now() - interval '$(( start + i - 1 )) minutes', false);"
  done
  docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -q >/dev/null 2>&1 <<SQL
BEGIN;
$stmts
COMMIT;
SQL
}

# Full reset: clears the rate-limit ledger, un-bridges any auth.users this
# suite created (so "creates a real auth.users row on first login" is
# exercised fresh every run, not just once ever), and (re)creates the
# throwaway cross-org fixture.
reset_state() {
  $have_psql || return 0
  docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -q >/dev/null 2>&1 <<SQL
TRUNCATE login_attempts;

-- The user_metadata self-heal test (section 2) renames Priya mid-run to
-- prove a later login corrects a stale name. Restored here defensively so a
-- partial/failed run never leaves seed data in a renamed state for anything
-- that runs after it.
UPDATE public.users SET name = 'Priya Nair' WHERE id = '$USER_PRIYA';

-- users_auth_user_id_fkey must be cleared BEFORE the auth.users row it points
-- to can be deleted (found the hard way: deleting auth.users first throws a
-- foreign key violation, which -q's error swallowing was hiding — every
-- statement below this point silently no-op'd on every run). Every row that
-- might still reference a synthetic-domain auth.users row is cleared FIRST —
-- either by nulling the column (rows we keep) or deleting the whole
-- public.users row (the throwaway cross-org fixture, recreated fresh below) —
-- and only THEN do we delete the now-unreferenced auth.users rows, matched by
-- email pattern rather than by joining back through auth_user_id (more
-- robust: cleans up regardless of the exact id bookkeeping above).
-- Null EVERY reference to a synthetic-domain auth.users row, not just this
-- suite's two — other suites in a full run (validate-magic-link's e2e bridges
-- a coach; this suite's section 8 bridges an Apex owner) leave their own
-- bridged rows, and if ANY reference survives, the DELETE below hits a FK
-- violation, silently no-ops under -q, and every suite that runs after this
-- one can't mint a session ("createUser: email already registered").
UPDATE public.users SET auth_user_id = NULL
 WHERE auth_user_id IN (SELECT id FROM auth.users WHERE email LIKE '%@staff.internal.invalid');
DELETE FROM public.users WHERE id = '$CROSS_ORG_USER';

DELETE FROM auth.users WHERE email LIKE '%@staff.internal.invalid';

INSERT INTO public.users (id, organization_id, name, phone, role, pin_hash)
VALUES ('$CROSS_ORG_USER', '$ORG_FLEX', 'Cross-Org Test Fixture', '$PHONE_PRIYA', 'front_desk', '$CROSS_ORG_PIN_HASH');
SQL
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

printf '\n%s== staff-login tests ==%s\n' "$B" "$N"
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
  if [ "$(sql "select count(*) from public.users where id='$USER_PRIYA';")" != "1" ]; then
    printf '\n%sERROR%s user fixtures missing. Run: supabase db reset\n\n' "$R" "$N"
    exit 1
  fi
  if [ "$(sql "select to_regclass('public.login_attempts') is not null;")" != "t" ]; then
    printf '\n%sERROR%s login_attempts table missing. Run: supabase db reset\n\n' "$R" "$N"
    exit 1
  fi
else
  printf '%swarn%s  docker/psql unavailable — DB assertions and fixtures will SKIP\n' "$Y" "$N"
fi

reset_state

# ---------------------------------------------------------------------------
# 0. CORS preflight — this is the one gap that made it to staging silently:
# nothing here was ever testing it. See ../_shared/cors.ts's header comment
# for why "worked locally" proved nothing on its own: this project's local
# Kong gateway answers OPTIONS automatically for every function regardless of
# the function's own code, which a real deployed function does NOT get for
# free. Pointing BASE_URL at a real deployed URL (not the local default) is
# how this section actually proves the function's OWN OPTIONS handler works,
# rather than Kong's local passthrough — same env-var override every other
# test.sh in this project already supports.
# ---------------------------------------------------------------------------
printf '\n%s-- CORS preflight --%s\n' "$B" "$N"

# Lowercased once — Kong's own local passthrough capitalizes header names
# differently than the function's own corsPreflightResponse() does; HTTP
# header names are case-insensitive by spec, so the assertions below should
# be too, rather than accidentally coupled to which layer answered.
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

assert_contains "unparseable body is a clear 400" '"error":"invalid_json_body"' "$(post_raw 'not json')"
assert_contains "missing organization_id is a clear 400" '"error":"organization_id_required"' "$(post_raw '{"phone":"x","pin":"1234"}')"
assert_contains "malformed organization_id is caught before Postgres" \
  '"error":"organization_id_malformed"' "$(post_raw "{\"organization_id\":\"nope\",\"phone\":\"$PHONE_PRIYA\",\"pin\":\"1234\"}")"
assert_contains "missing phone is a clear 400" '"error":"phone_required"' \
  "$(post_raw "{\"organization_id\":\"$ORG_IRON\",\"pin\":\"1234\"}")"
assert_contains "missing pin is a clear 400" '"error":"pin_required"' \
  "$(post_raw "{\"organization_id\":\"$ORG_IRON\",\"phone\":\"$PHONE_PRIYA\"}")"
assert_contains "non-numeric pin is a clear 400" '"error":"pin_malformed"' \
  "$(post "$ORG_IRON" "$PHONE_PRIYA" "abcd")"

got=$(curl -s -X GET "$BASE_URL" -H "Authorization: Bearer $ANON_KEY")
assert_contains "GET is rejected (this endpoint is POST-only)" 'method_not_allowed' "$got"

assert_db "no rejected request wrote a login_attempts row" "0" "$(sql "select count(*) from login_attempts;")"

# ---------------------------------------------------------------------------
# 2. Correct PIN succeeds with a real session
# ---------------------------------------------------------------------------
printf '\n%s-- correct pin succeeds --%s\n' "$B" "$N"

got=$(post "$ORG_IRON" "$PHONE_PRIYA" "$PIN_PRIYA")
assert_contains "correct pin returns ok:true"        '"ok":true' "$got"
assert_contains "response has a real access_token"    '"access_token":"ey' "$got"
assert_contains "response has a refresh_token"        '"refresh_token":"' "$got"
assert_contains "response has token_type bearer"      '"token_type":"bearer"' "$got"
assert_contains "response carries the staff name"     '"name":"Priya Nair"' "$got"
assert_contains "response carries the role"           '"role":"front_desk"' "$got"
assert_contains "response carries organization_id"    "\"organization_id\":\"$ORG_IRON\"" "$got"

ACCESS_TOKEN=$(field access_token "$got")
EXPIRES_IN=$(field_num expires_in "$got")
assert_equals "expires_in matches jwt_expiry (3600s)" "3600" "$EXPIRES_IN"

if [ -n "$ACCESS_TOKEN" ]; then
  case "$ACCESS_TOKEN" in
    ey*.*.*) ok "access_token looks like a real JWT (three dot-separated segments)" ;;
    *)       bad "access_token looks like a real JWT" "ey...*.*.*" "$ACCESS_TOKEN" ;;
  esac
else
  bad "an access_token was returned" "a JWT string" "(none)"
fi

assert_db "a real auth.users row now exists for Priya" \
  "1" "$(sql "select count(*) from auth.users where id = (select auth_user_id from public.users where id='$USER_PRIYA');")"
assert_db "the auth.users row uses the synthetic staff.internal.invalid email" \
  "1" "$(sql "select count(*) from auth.users where id = (select auth_user_id from public.users where id='$USER_PRIYA') and email = '$USER_PRIYA@staff.internal.invalid';")"
assert_db "successful login was recorded" \
  "1" "$(sql "select count(*) from login_attempts where organization_id='$ORG_IRON' and phone='$PHONE_PRIYA' and success=true;")"

# --- user_metadata set correctly at creation time ---
assert_db "auth.users.user_metadata.name is set on first login" \
  "Priya Nair" "$(sql "select raw_user_meta_data->>'name' from auth.users where email='$USER_PRIYA@staff.internal.invalid';")"
assert_db "auth.users.user_metadata.role is set on first login" \
  "front_desk" "$(sql "select raw_user_meta_data->>'role' from auth.users where email='$USER_PRIYA@staff.internal.invalid';")"

# --- Second login must NOT create a second auth.users row ---
got2=$(post "$ORG_IRON" "$PHONE_PRIYA" "$PIN_PRIYA")
assert_contains "second correct login also succeeds" '"ok":true' "$got2"
assert_db "still exactly one auth.users row for Priya (no duplicate on re-login)" \
  "1" "$(sql "select count(*) from auth.users where email='$USER_PRIYA@staff.internal.invalid';")"

# --- Self-heal: a name change in public.users is picked up on the NEXT login,
# --- for an account that was already provisioned (not just at creation) ---
sql "update public.users set name='Priya Nair (Renamed)' where id='$USER_PRIYA';" >/dev/null
got3=$(post "$ORG_IRON" "$PHONE_PRIYA" "$PIN_PRIYA")
assert_contains "login after a name change still succeeds"          '"ok":true' "$got3"
assert_contains "the response reflects the NEW name immediately"    '"name":"Priya Nair (Renamed)"' "$got3"
assert_db "user_metadata.name self-healed to the new name" \
  "Priya Nair (Renamed)" "$(sql "select raw_user_meta_data->>'name' from auth.users where email='$USER_PRIYA@staff.internal.invalid';")"
assert_db "still exactly one auth.users row (sync updates, does not duplicate)" \
  "1" "$(sql "select count(*) from auth.users where email='$USER_PRIYA@staff.internal.invalid';")"
sql "update public.users set name='Priya Nair' where id='$USER_PRIYA';" >/dev/null

# ---------------------------------------------------------------------------
# 3. Wrong PIN fails without revealing account existence
# ---------------------------------------------------------------------------
printf '\n%s-- wrong pin / nonexistent phone --%s\n' "$B" "$N"

reset_state

wrong=$(post "$ORG_IRON" "$PHONE_PRIYA" "0000")
missing=$(post "$ORG_IRON" "$PHONE_NONEXISTENT" "0000")

assert_contains "wrong pin for a real phone is 401 invalid_credentials"   '"error":"invalid_credentials"' "$wrong"
assert_contains "nonexistent phone is ALSO 401 invalid_credentials"       '"error":"invalid_credentials"' "$missing"
assert_equals   "wrong-pin and not-found response bodies are byte-identical" "$wrong" "$missing"
assert_not_contains "invalid_credentials never carries an access_token"   'access_token' "$wrong"

assert_db "wrong pin recorded a failed attempt for the real phone" \
  "1" "$(sql "select count(*) from login_attempts where organization_id='$ORG_IRON' and phone='$PHONE_PRIYA' and success=false;")"
assert_db "nonexistent phone ALSO recorded a failed attempt (same rate-limit treatment)" \
  "1" "$(sql "select count(*) from login_attempts where organization_id='$ORG_IRON' and phone='$PHONE_NONEXISTENT' and success=false;")"

reset_state

# ---------------------------------------------------------------------------
# 4. Cross-org: same phone at a DIFFERENT org must not authenticate
# ---------------------------------------------------------------------------
printf '\n%s-- cross-org phone --%s\n' "$B" "$N"

got=$(post "$ORG_FLEX" "$PHONE_PRIYA" "$PIN_PRIYA")
assert_contains "FlexFit + Priya's phone + Iron Temple's correct pin is rejected" \
  '"error":"invalid_credentials"' "$got"

got=$(post "$ORG_FLEX" "$PHONE_PRIYA" "$CROSS_ORG_PIN")
assert_contains "FlexFit + that phone + the FLEXFIT fixture's own correct pin succeeds" '"ok":true' "$got"
assert_contains "it authenticates as the FlexFit fixture, not Priya" '"name":"Cross-Org Test Fixture"' "$got"

reset_state

# ---------------------------------------------------------------------------
# 5. Lockout — 5 real failures locks the account
# ---------------------------------------------------------------------------
printf '\n%s-- lockout after 5 failures --%s\n' "$B" "$N"

for i in 1 2 3 4 5; do
  got=$(post "$ORG_IRON" "$PHONE_RAVI" "9999")
  assert_contains "wrong-pin attempt #$i is 401, not locked yet" '"error":"invalid_credentials"' "$got"
done

got=$(post "$ORG_IRON" "$PHONE_RAVI" "9999")
assert_contains "6th attempt is locked out"  '"error":"too_many_attempts"' "$got"
assert_equals   "lockout returns 429"        "429" "$(post_status "$ORG_IRON" "$PHONE_RAVI" "9999")"
retry=$(field_num retry_after_seconds "$got")
if [ -n "$retry" ] && [ "$retry" -gt 0 ] && [ "$retry" -le 900 ]; then
  ok "retry_after_seconds is a sane value (0, 900]: $retry"
else
  bad "retry_after_seconds is a sane value (0, 900]" "1..900" "${retry:-<missing>}"
fi

assert_db "lockout does not add a 7th login_attempts row" \
  "5" "$(sql "select count(*) from login_attempts where organization_id='$ORG_IRON' and phone='$PHONE_RAVI';")"

# --- The account rejects even the CORRECT pin while locked ---
got=$(post "$ORG_IRON" "$PHONE_RAVI" "$PIN_RAVI")
assert_contains "correct pin is STILL rejected during lockout" '"error":"too_many_attempts"' "$got"
assert_db "the correct-pin attempt during lockout was not recorded either" \
  "5" "$(sql "select count(*) from login_attempts where organization_id='$ORG_IRON' and phone='$PHONE_RAVI';")"

reset_state

# ---------------------------------------------------------------------------
# 6. Lockout expires after the cooldown window
# ---------------------------------------------------------------------------
printf '\n%s-- lockout expires after cooldown --%s\n' "$B" "$N"

# 5 failures backdated to 20-24 minutes ago — older than both the 15-minute
# detection window and the 15-minute cooldown, so the lock has already lifted.
arrange_failed_attempts "$ORG_IRON" "$PHONE_RAVI" 5 20

got=$(post "$ORG_IRON" "$PHONE_RAVI" "$PIN_RAVI")
assert_contains "correct pin succeeds once the backdated failures have aged out" '"ok":true' "$got"

reset_state

# A fresh-but-still-within-window case, to prove the cooldown is real and not
# a no-op: 5 failures just 2 minutes old must still be locked.
arrange_failed_attempts "$ORG_IRON" "$PHONE_RAVI" 5 2
got=$(post "$ORG_IRON" "$PHONE_RAVI" "$PIN_RAVI")
assert_contains "5 failures from 2-6 minutes ago still lock the account" '"error":"too_many_attempts"' "$got"

reset_state

# ---------------------------------------------------------------------------
# 7. A successful login resets the failure counter
# ---------------------------------------------------------------------------
printf '\n%s-- success resets the counter --%s\n' "$B" "$N"

for i in 1 2 3 4; do post "$ORG_IRON" "$PHONE_RAVI" "9999" >/dev/null; done
assert_db "4 failures recorded, not yet locked" \
  "4" "$(sql "select count(*) from login_attempts where organization_id='$ORG_IRON' and phone='$PHONE_RAVI' and success=false;")"

got=$(post "$ORG_IRON" "$PHONE_RAVI" "$PIN_RAVI")
assert_contains "the correct pin on attempt #5 still succeeds (not locked yet)" '"ok":true' "$got"

# Now 4 MORE wrong attempts — if the counter had not reset, this would be the
# 8th failure overall and would already be locked. It must not be.
for i in 1 2 3 4; do post "$ORG_IRON" "$PHONE_RAVI" "9999" >/dev/null; done
got=$(post "$ORG_IRON" "$PHONE_RAVI" "9999")
assert_contains "still not locked — the success above reset the counter" '"error":"invalid_credentials"' "$got"
assert_not_contains "confirms it did not lock out yet" 'too_many_attempts' "$got"

reset_state

# ---------------------------------------------------------------------------
# 8. Suspended organization — the PIN is right, access is on hold
#    (org-status enforcement 20260902090000). Apex Strength Co is seeded
#    status='suspended'.
# ---------------------------------------------------------------------------
printf '\n%s-- suspended organization --%s\n' "$B" "$N"
ORG_APEX=a9ec0000-0000-0000-0000-0000000000a1

got=$(post "$ORG_APEX" 919100000001 2580)   # Nisha Raman, Apex owner, correct PIN
assert_contains "correct PIN at a SUSPENDED org -> org_suspended"      '"error":"org_suspended"' "$got"
assert_contains "  ...carries a human-readable message"               '"message":"' "$got"
assert_equals   "  ...403, not 200"                                   "403" "$(post_status "$ORG_APEX" 919100000001 2580)"
assert_contains "  ...a WRONG PIN at a suspended org is still generic" '"error":"invalid_credentials"' \
  "$(post "$ORG_APEX" 919100000001 9999)"

if $have_psql; then
  sql "update organizations set status='active' where id='$ORG_APEX'" >/dev/null
  assert_equals "reactivating restores login with no other action -> 200" "200" \
    "$(post_status "$ORG_APEX" 919100000001 2580)"
  sql "update organizations set status='suspended' where id='$ORG_APEX'" >/dev/null
  assert_equals "re-suspending blocks it again -> 403" "403" \
    "$(post_status "$ORG_APEX" 919100000001 2580)"
fi

reset_state

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
