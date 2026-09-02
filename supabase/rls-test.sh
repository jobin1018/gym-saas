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
# A membership + payment for MEMBER_LOC2 (HSR Layout) — section 14's proof that
# v_payments_ledger excludes another location's transactions for front_desk.
MEMBERSHIP_LOC2=0daded00-1111-0000-0000-0000000000b2
PAYMENT_LOC2=0daded00-1111-0000-0000-0000000000c2

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

# rest_post_status <token> <path> <json-body> -> HTTP status only (POST/insert)
rest_post_status() {
  curl -s -o /dev/null -w '%{http_code}' -X POST "$REST_URL/$2" \
    -H "apikey: $ANON_KEY" -H "Authorization: Bearer $1" \
    -H 'Content-Type: application/json' -H 'Prefer: return=representation' -d "$3"
}

# rest_post <token> <path> <json-body> -> response body (POST/insert, returns the row)
rest_post() {
  curl -s -X POST "$REST_URL/$2" \
    -H "apikey: $ANON_KEY" -H "Authorization: Bearer $1" \
    -H 'Content-Type: application/json' -H 'Prefer: return=representation' -d "$3"
}

# rest_patch_status <token> <path-and-filter> <json-body> -> HTTP status only (PATCH/update)
rest_patch_status() {
  curl -s -o /dev/null -w '%{http_code}' -X PATCH "$REST_URL/$2" \
    -H "apikey: $ANON_KEY" -H "Authorization: Bearer $1" \
    -H 'Content-Type: application/json' -H 'Prefer: return=representation' -d "$3"
}

# rest_rpc <token> <fn-name> <json-body> -> response body (POST /rpc/<fn>)
rest_rpc() {
  curl -s -X POST "$REST_URL/rpc/$2" \
    -H "apikey: $ANON_KEY" -H "Authorization: Bearer $1" \
    -H 'Content-Type: application/json' -d "$3"
}

# rest_rpc_status <token> <fn-name> <json-body> -> HTTP status only, newline-terminated
rest_rpc_status() {
  curl -s -o /dev/null -w '%{http_code}\n' -X POST "$REST_URL/rpc/$2" \
    -H "apikey: $ANON_KEY" -H "Authorization: Bearer $1" \
    -H 'Content-Type: application/json' -d "$3"
}

# rest_range <token> <path-and-query> -> the Content-Range value (needs Prefer: count=exact)
rest_range() {
  curl -s -D - -o /dev/null "$REST_URL/$2" \
    -H "apikey: $ANON_KEY" -H "Authorization: Bearer $1" -H 'Prefer: count=exact' \
    | tr -d '\r' | sed -n 's/^[Cc]ontent-[Rr]ange: *//p'
}

# rest_page <token> <path-and-query> <start-end> -> response body for that page.
# The HTTP Range header IS what supabase-js's .range(from, to) sends on the
# wire — same mechanism coachWrites.getSessionHistory() already uses.
rest_page() {
  curl -s "$REST_URL/$2" \
    -H "apikey: $ANON_KEY" -H "Authorization: Bearer $1" \
    -H 'Prefer: count=exact' -H "Range-Unit: items" -H "Range: $3"
}

# rest_page_range <token> <path-and-query> <start-end> -> the Content-Range value for that page
rest_page_range() {
  curl -s -D - -o /dev/null "$REST_URL/$2" \
    -H "apikey: $ANON_KEY" -H "Authorization: Bearer $1" \
    -H 'Prefer: count=exact' -H "Range-Unit: items" -H "Range: $3" \
    | tr -d '\r' | sed -n 's/^[Cc]ontent-[Rr]ange: *//p'
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
-- section 15's freeze fixtures. membership_freezes has no ON DELETE CASCADE
-- to memberships (deliberate — see 20260904090000's header), so these MUST
-- go before the membership/member deletes below, same FK-ordering discipline
-- as body_measurements-before-training_notes further down. The two throwaway
-- memberships (expired-status fixture, elapsed-days-shift fixture) are
-- deleted outright so re-running this suite without a fresh \`db reset\`
-- cannot compound a current_period_end shift; Asha's real seed membership is
-- only ever round-tripped same-day (net shift zero) so a bare status restore
-- is enough for it.
DELETE FROM membership_freezes WHERE membership_id IN
  ('f1111111-1111-1111-1111-111111111111', '$MEMBERSHIP_LOC2',
   '0daded00-1111-0000-0000-0000000000e1', '0daded00-1111-0000-0000-0000000000e2');
DELETE FROM memberships
 WHERE id IN ('0daded00-1111-0000-0000-0000000000e1', '0daded00-1111-0000-0000-0000000000e2');
UPDATE memberships SET status = 'active'
 WHERE id = 'f1111111-1111-1111-1111-111111111111' AND status = 'frozen';
DELETE FROM payments WHERE id = '$PAYMENT_LOC2';
DELETE FROM attendance WHERE member_id = '$MEMBER_LOC2';
DELETE FROM memberships WHERE member_id = '$MEMBER_LOC2';
DELETE FROM members WHERE id = '$MEMBER_LOC2';
DELETE FROM locations WHERE id = '$LOC_IRON_2';
DELETE FROM whatsapp_messages WHERE body_preview IN ('rls-test broadcast', 'rls-test member message');
UPDATE organizations SET gst_number = NULL WHERE id = '$ORG_FLEX';
-- section 13 suspends/reactivates FlexFit; make sure a mid-run abort can't
-- leave it frozen for the next run.
UPDATE organizations SET status = 'active' WHERE id IN ('$ORG_IRON', '$ORG_FLEX');
-- coaching section's own inserts (seed rows carry none of these markers).
-- body_measurements FIRST — it FK-references training_notes now.
DELETE FROM body_measurements
 WHERE weight_kg = 77.77
    OR member_id IN ('80000000-0000-0000-0000-000000000004',   -- Ritu: fixture-only coaching data
                     '80000000-0000-0000-0000-000000000005')   -- Ajay: fixture-only coaching data
    OR training_note_id IN (SELECT id FROM training_notes WHERE note_text LIKE 'rls-test%');
DELETE FROM training_notes
 WHERE note_text LIKE 'rls-test%'
    OR pt_package_id IN ('9c000000-0000-0000-0000-0000000000f1',
                         '9c000000-0000-0000-0000-0000000000f3');
-- PT payment rows spawned by the pt_packages_record_payment trigger for every
-- non-seed package this suite creates (must go before their pt_packages).
DELETE FROM payments
 WHERE idempotency_key LIKE 'ptpkg-%'
   AND pt_package_id NOT IN (
     '9c000000-0000-0000-0000-000000000001','9c000000-0000-0000-0000-000000000002',
     '9c000000-0000-0000-0000-000000000003','9c000000-0000-0000-0000-000000000004',
     '9c000000-0000-0000-0000-000000000005');
DELETE FROM pt_packages
 WHERE (price >= 4321.00 AND price < 4400.00)   -- 4321.xx: this suite's created packages
    OR id IN ('9c000000-0000-0000-0000-0000000000f1',
              '9c000000-0000-0000-0000-0000000000f3',
              '9c000000-0000-0000-0000-0000000000f5');
-- the session-count trigger bumps sessions_used on every note; deleting the
-- note does not undo the bump, so restore the one seed package the coaching
-- section writes a real note against (keeps repeated runs without `db reset`
-- stable).
UPDATE pt_packages SET sessions_used = 8, status = 'active'
 WHERE id = '9c000000-0000-0000-0000-000000000001';
-- section 10: membership_plans CRUD test rows (no memberships attached, safe to drop)
DELETE FROM membership_plans WHERE name LIKE 'rls-test plan%';
SQL
}

arrange_fixtures() {
  $have_psql || return 0
  docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -q >/dev/null 2>&1 <<SQL
INSERT INTO locations (id, organization_id, name)
VALUES ('$LOC_IRON_2', '$ORG_IRON', 'Iron Temple — HSR Layout');

INSERT INTO members (id, organization_id, location_id, name, phone, whatsapp_opt_in, source)
VALUES ('$MEMBER_LOC2', '$ORG_IRON', '$LOC_IRON_2', 'Second-Location Test Member', '919000055501', true, 'manual');

-- A reconciled membership payment at HSR Layout, for section 14
-- (v_payments_ledger) — front_desk @ Indiranagar must never see it.
INSERT INTO memberships (id, organization_id, member_id, plan_id, status, start_date, current_period_end)
VALUES ('$MEMBERSHIP_LOC2', '$ORG_IRON', '$MEMBER_LOC2', 'cccccccc-cccc-cccc-cccc-cccccccccccc',
        'active', CURRENT_DATE, CURRENT_DATE + 30);
INSERT INTO payments (id, organization_id, membership_id, amount, provider, provider_payment_id,
                      status, idempotency_key, reconciled_at)
VALUES ('$PAYMENT_LOC2', '$ORG_IRON', '$MEMBERSHIP_LOC2', 1500.00, 'razorpay', 'pay_rlstest_loc2',
        'success', 'rls-test-loc2-payment', now());

UPDATE organizations SET gst_number = '29AAAAA0000A1Z5' WHERE id = '$ORG_IRON';

INSERT INTO whatsapp_messages (organization_id, member_id, direction, template_name, body_preview, status)
VALUES ('$ORG_IRON', NULL, 'outbound', 'daily_owner_brief', 'rls-test broadcast', 'queued');

INSERT INTO whatsapp_messages (organization_id, member_id, direction, template_name, body_preview, status)
VALUES ('$ORG_IRON', 'e2222222-2222-2222-2222-222222222222', 'outbound', 'renewal_reminder', 'rls-test member message', 'queued');

-- Coaching fixtures for the log_session / session-count / pagination tests.
-- Both: Farah (c0ac...01) is the coach; Ritu / Ajay are otherwise-uncoached
-- Indiranagar members so this suite fully owns their coaching rows.
--   f1: 5 purchased, 0 used  -> the pagination + auto-complete-at-5 package
--   f3: 5 purchased, 4 used  -> the concurrent-boundary (race) package
INSERT INTO pt_packages
  (id, organization_id, member_id, coach_id, goal,
   duration_months, sessions_per_month, sessions_purchased, sessions_used, price, status, start_date)
VALUES
  ('9c000000-0000-0000-0000-0000000000f1', '$ORG_IRON', '80000000-0000-0000-0000-000000000004',
   'c0ac0000-0000-0000-0000-000000000001', 'fat_loss', 1, 5, 5, 0, 5000.00, 'active', CURRENT_DATE),
  ('9c000000-0000-0000-0000-0000000000f3', '$ORG_IRON', '80000000-0000-0000-0000-000000000005',
   'c0ac0000-0000-0000-0000-000000000001', 'general_fitness', 1, 5, 5, 4, 5000.00, 'active', CURRENT_DATE),
  -- f5: 1 session left -> shows in v_pt_packages_attention (low_sessions).
  -- price 0 so the pt_packages_record_payment trigger creates no payment row.
  -- Manoj (8000..03) is otherwise unreferenced by this suite.
  ('9c000000-0000-0000-0000-0000000000f5', '$ORG_IRON', '80000000-0000-0000-0000-000000000003',
   'c0ac0000-0000-0000-0000-000000000001', 'muscle_gain', 1, 5, 5, 4, 0, 'active', CURRENT_DATE);
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
FARAH=$(login "$ORG_IRON" 918454000001 1234)   # coach, Iron — clients: Asha, Deepak
GIRISH=$(login "$ORG_IRON" 918454000002 1234)  # coach, Iron — client: Sneha
HEMA=$(login "$ORG_FLEX" 918454000003 1234)    # coach, FlexFit — client: Chitra (FF)

if [ -z "$RAVI" ] || [ -z "$PRIYA" ] || [ -z "$SANJAY" ]; then
  printf '\n%sERROR%s could not mint one or more sessions — check staff-login / seed.sql.\n\n' "$R" "$N"
  exit 1
fi
if [ -z "$FARAH" ] || [ -z "$GIRISH" ] || [ -z "$HEMA" ]; then
  printf '\n%sERROR%s could not mint coach sessions — check the coach role / seed.sql PT section.\n\n' "$R" "$N"
  exit 1
fi
ok "minted real sessions for Ravi (Iron owner), Priya (Iron front_desk), Sanjay (FlexFit owner)"
ok "minted real coach sessions for Farah + Girish (Iron) and Hema (FlexFit)"

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

for table in organizations locations members membership_plans memberships payments attendance whatsapp_messages organizations_for_client pt_packages training_notes body_measurements; do
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

# Corrupt the last 8 chars of the signature, not just the last 1: a single
# base64url char at the end of an ES256 signature carries only 2 significant
# bits, so a 1-char flip decodes to the SAME signature bytes ~1 time in 16 —
# which is why this case used to fail intermittently.
TAMPERED="${RAVI%????????}AAAAAAAA"
if [ "$TAMPERED" = "$RAVI" ]; then
  bad "tampering actually changed the token" "a different string" "identical (test bug)"
else
  status=$(rest_status "$TAMPERED" "members?select=id")
  assert_equals "a tampered access_token is rejected 401" "401" "$status"
  body=$(rest "$TAMPERED" "members?select=id")
  assert_contains "the rejection names a JWT/key problem, not a data answer" "PGRST301" "$body"
fi

# ---------------------------------------------------------------------------
# 8. PT coaching — assignment-scoped, NOT location-scoped
# ---------------------------------------------------------------------------
# Seed (supabase/seed.sql PT section):
#   Farah  -> Asha Menon (e1111111)          active   pkg 9c..01
#   Farah  -> Deepak Kumar (8000..01)        active   pkg 9c..02
#   Girish -> Sneha Gupta (8000..02)         active   pkg 9c..03
#   Farah  -> Chitra Iyer Iron (e3333333)    COMPLETED pkg 9c..04
#   Hema   -> Chitra Iyer FlexFit (e4444444) active   pkg 9c..05
#   Bharat Rao (e2222222) — no package at all
printf '\n%s-- PT coaching: assignment-scoped access --%s\n' "$B" "$N"

ASHA=e1111111-1111-1111-1111-111111111111
DEEPAK=80000000-0000-0000-0000-000000000001
SNEHA=80000000-0000-0000-0000-000000000002
RITU=80000000-0000-0000-0000-000000000004        # Farah's fixture package f1 (arrange_fixtures)
POOJA=80000000-0000-0000-0000-000000000006       # Indiranagar member, never assigned to any coach
CHITRA_IRON=e3333333-3333-3333-3333-333333333333 # Farah's package is COMPLETED
BHARAT=e2222222-2222-2222-2222-222222222222      # no package
CHITRA_FF=e4444444-4444-4444-4444-444444444444
FARAH_UID=c0ac0000-0000-0000-0000-000000000001
GIRISH_UID=c0ac0000-0000-0000-0000-000000000002
PKG_ASHA=9c000000-0000-0000-0000-000000000001
PKG_SNEHA=9c000000-0000-0000-0000-000000000003
PKG_CHITRA_DONE=9c000000-0000-0000-0000-000000000004

# --- a coach sees every member assigned to them, ANY package status
#     (completed-package history included, per 20260829097000) — but NOT
#     unassigned members at their own branch ---
got=$(rest "$FARAH" "members?organization_id=eq.$ORG_IRON&select=id")
assert_contains     "Farah sees Asha (active assignment)"          "$ASHA" "$got"
assert_contains     "Farah sees Deepak (active assignment)"        "$DEEPAK" "$got"
assert_contains     "Farah sees Chitra — completed-package history (097000)" "$CHITRA_IRON" "$got"
assert_not_contains "Farah does NOT see Sneha (Girish's client)"   "$SNEHA" "$got"
assert_not_contains "Farah does NOT see Bharat (no package)"       "$BHARAT" "$got"
assert_not_contains "Farah does NOT see Pooja (Indiranagar, no coach assignment) — proves NOT location-scoped" "$POOJA" "$got"

got=$(rest "$GIRISH" "members?organization_id=eq.$ORG_IRON&select=id")
assert_contains     "Girish sees Sneha"                            "$SNEHA" "$got"
assert_not_contains "Girish does NOT see Asha"                     "$ASHA" "$got"

# --- pt_packages: coach sees every package assigned to them (any status);
#     other coaches' packages stay hidden ---
got=$(rest "$FARAH" "pt_packages?select=id,status")
assert_contains     "Farah sees her active package for Asha"       "$PKG_ASHA" "$got"
assert_not_contains "Farah does NOT see Girish's package"          "$PKG_SNEHA" "$got"
assert_contains     "Farah DOES see her own COMPLETED package (history)" "$PKG_CHITRA_DONE" "$got"
assert_equals       "Farah's pt_packages read is 200"             "200" "$(rest_status "$FARAH" "pt_packages?select=id")"

got=$(rest "$RAVI" "pt_packages?select=id,status")
assert_contains "Ravi (owner) still sees the completed package"    "$PKG_CHITRA_DONE" "$got"

# --- coach retains READ on an inactive package, but NO write of any kind
#     (migration 20260829093000: only the coach SELECT branch widened) ---
got=$(rest "$FARAH" "pt_packages?id=eq.$PKG_CHITRA_DONE&select=id,status,member_id,goal")
assert_contains "Farah can SELECT the completed package by id"     "$PKG_CHITRA_DONE" "$got"
assert_contains "  ...and it really is the completed one"          '"status":"completed"' "$got"
assert_contains "  ...and it carries the assigned member"          "$CHITRA_IRON" "$got"

NOTE_DONE="{\"organization_id\":\"$ORG_IRON\",\"member_id\":\"$CHITRA_IRON\",\"coach_id\":\"$FARAH_UID\",\"pt_package_id\":\"$PKG_CHITRA_DONE\",\"note_text\":\"rls-test on a completed pkg\"}"
assert_equals "Farah CANNOT add a training_note against the completed package"       "403" "$(rest_post_status "$FARAH" "training_notes" "$NOTE_DONE")"
BM_DONE="{\"organization_id\":\"$ORG_IRON\",\"member_id\":\"$CHITRA_IRON\",\"recorded_by\":\"$FARAH_UID\",\"weight_kg\":77.77,\"height_cm\":175}"
assert_equals "Farah CANNOT add a measurement for a member whose package is completed" "403" "$(rest_post_status "$FARAH" "body_measurements" "$BM_DONE")"
assert_equals "Farah CANNOT UPDATE the completed package itself"                     "403" "$(rest_patch_status "$FARAH" "pt_packages?id=eq.$PKG_CHITRA_DONE" '{"sessions_used":15}')"
assert_equals "Farah's read of the completed-package member's training_notes is permitted, not 403" "200" "$(rest_status "$FARAH" "training_notes?member_id=eq.$CHITRA_IRON&select=id")"
assert_contains "post-097000 the completed-package member IS on Farah's member list (history)" "$CHITRA_IRON" "$(rest "$FARAH" "members?organization_id=eq.$ORG_IRON&select=id")"

got=$(rest "$PRIYA" "pt_packages?select=id")
priya_pkgs=$(count_rows "$got")
if [ "$priya_pkgs" -ge 4 ] 2>/dev/null; then
  ok "Priya (front_desk) sees her location's packages ($priya_pkgs)"
else
  bad "Priya (front_desk) sees her location's packages" ">=4" "$priya_pkgs"
fi

# --- training_notes / body_measurements: coach scoped, front_desk shut out ---
got=$(rest "$FARAH" "training_notes?select=note_text")
assert_contains     "Farah sees Asha's session note"              "Increased squat" "$got"
assert_not_contains "Farah does NOT see Girish's note for Sneha"  "Mobility work" "$got"
got=$(rest "$GIRISH" "training_notes?select=note_text")
assert_contains     "Girish sees his note for Sneha"              "Mobility work" "$got"
assert_not_contains "Girish does NOT see Farah's note for Asha"   "Increased squat" "$got"

assert_equals "Priya (front_desk) sees zero training_notes"       "0" "$(count_rows "$(rest "$PRIYA" "training_notes?select=id")")"
assert_equals "Priya's training_notes read is 200, not 403"       "200" "$(rest_status "$PRIYA" "training_notes?select=id")"
assert_equals "Priya (front_desk) sees zero body_measurements"    "0" "$(count_rows "$(rest "$PRIYA" "body_measurements?select=id")")"

got=$(rest "$FARAH" "body_measurements?member_id=eq.$ASHA&select=id")
farah_bm=$(count_rows "$got")
if [ "$farah_bm" -gt 0 ] 2>/dev/null; then ok "Farah sees Asha's measurements ($farah_bm)"; else bad "Farah sees Asha's measurements" ">0" "$farah_bm"; fi
assert_equals "Farah sees zero measurements for Sneha (not hers)" "0" "$(count_rows "$(rest "$FARAH" "body_measurements?member_id=eq.$SNEHA&select=id")")"

# --- "most recent height" query + generated BMI ---
got=$(rest "$FARAH" "body_measurements?member_id=eq.$ASHA&select=weight_kg,height_cm,bmi&order=recorded_at.desc&limit=1")
assert_contains "most-recent measurement carries the last-recorded height (176)" '"height_cm":176' "$got"
assert_contains "generated BMI is correct for 72.0kg / 176cm (23.2)"             '"bmi":23.2' "$got"

# --- writes: coach can log only for active-assigned clients ---
NOTE_OK="{\"organization_id\":\"$ORG_IRON\",\"member_id\":\"$ASHA\",\"coach_id\":\"$FARAH_UID\",\"pt_package_id\":\"$PKG_ASHA\",\"note_text\":\"rls-test squat pr\"}"
assert_equals "Farah CAN add a note for Asha (active package)"    "201" "$(rest_post_status "$FARAH" "training_notes" "$NOTE_OK")"
NOTE_BAD="{\"organization_id\":\"$ORG_IRON\",\"member_id\":\"$BHARAT\",\"coach_id\":\"$FARAH_UID\",\"pt_package_id\":\"$PKG_ASHA\",\"note_text\":\"rls-test nope\"}"
assert_equals "Farah CANNOT add a note for Bharat (no package)"   "403" "$(rest_post_status "$FARAH" "training_notes" "$NOTE_BAD")"
NOTE_SPOOF="{\"organization_id\":\"$ORG_IRON\",\"member_id\":\"$SNEHA\",\"coach_id\":\"$GIRISH_UID\",\"pt_package_id\":\"$PKG_SNEHA\",\"note_text\":\"rls-test spoof\"}"
assert_equals "Farah CANNOT add a note as Girish for Sneha"       "403" "$(rest_post_status "$FARAH" "training_notes" "$NOTE_SPOOF")"

BM_OK="{\"organization_id\":\"$ORG_IRON\",\"member_id\":\"$ASHA\",\"recorded_by\":\"$FARAH_UID\",\"weight_kg\":77.77,\"height_cm\":180}"
assert_equals "Farah CAN add a measurement for Asha"              "201" "$(rest_post_status "$FARAH" "body_measurements" "$BM_OK")"
BM_BAD="{\"organization_id\":\"$ORG_IRON\",\"member_id\":\"$SNEHA\",\"recorded_by\":\"$FARAH_UID\",\"weight_kg\":77.77,\"height_cm\":170}"
assert_equals "Farah CANNOT add a measurement for Sneha"          "403" "$(rest_post_status "$FARAH" "body_measurements" "$BM_BAD")"

got=$(rest "$FARAH" "body_measurements?member_id=eq.$ASHA&select=bmi&weight_kg=eq.77.77")
assert_contains "generated BMI is correct for the 77.77kg / 180cm insert (24.0)" '"bmi":24' "$got"

# --- writes: coach cannot create/modify packages; front_desk can ---
PKG_BY_COACH="{\"organization_id\":\"$ORG_IRON\",\"member_id\":\"$ASHA\",\"coach_id\":\"$FARAH_UID\",\"goal\":\"fat_loss\",\"sessions_purchased\":10,\"price\":4321.00}"
assert_equals "Farah (coach) CANNOT create a pt_package"          "403" "$(rest_post_status "$FARAH" "pt_packages" "$PKG_BY_COACH")"
PKG_BY_FD="{\"organization_id\":\"$ORG_IRON\",\"member_id\":\"$ASHA\",\"coach_id\":\"$GIRISH_UID\",\"goal\":\"general_fitness\",\"sessions_purchased\":6,\"price\":4321.00}"
assert_equals "Priya (front_desk) CAN create a pt_package + assign a coach" "201" "$(rest_post_status "$PRIYA" "pt_packages" "$PKG_BY_FD")"
PKG_BAD_COACH="{\"organization_id\":\"$ORG_IRON\",\"member_id\":\"$ASHA\",\"coach_id\":\"91111111-1111-1111-1111-111111111111\",\"goal\":\"fat_loss\",\"sessions_purchased\":5,\"price\":4321.00}"
assert_equals "assigning a NON-coach user as coach_id is rejected (trigger)" "400" "$(rest_post_status "$PRIYA" "pt_packages" "$PKG_BAD_COACH")"

# --- sessions_purchased derived from duration_months * sessions_per_month,
#     but overridable (migration 20260829098500) ---
PKG_DERIVE="{\"organization_id\":\"$ORG_IRON\",\"member_id\":\"$ASHA\",\"coach_id\":\"$GIRISH_UID\",\"goal\":\"muscle_gain\",\"duration_months\":6,\"sessions_per_month\":4,\"price\":4321.10}"
got=$(rest_post "$PRIYA" "pt_packages?select=duration_months,sessions_per_month,sessions_purchased" "$PKG_DERIVE")
assert_contains "6-month x 4/month package derives sessions_purchased = 24" '"sessions_purchased":24' "$got"

PKG_1MO="{\"organization_id\":\"$ORG_IRON\",\"member_id\":\"$ASHA\",\"coach_id\":\"$GIRISH_UID\",\"goal\":\"fat_loss\",\"duration_months\":1,\"sessions_per_month\":8,\"price\":4321.20}"
got=$(rest_post "$PRIYA" "pt_packages?select=sessions_purchased" "$PKG_1MO")
assert_contains "1-month x 8/month package still derives 8 (no regression)" '"sessions_purchased":8' "$got"

PKG_OVERRIDE="{\"organization_id\":\"$ORG_IRON\",\"member_id\":\"$ASHA\",\"coach_id\":\"$GIRISH_UID\",\"goal\":\"fat_loss\",\"duration_months\":6,\"sessions_per_month\":4,\"sessions_purchased\":25,\"price\":4321.30}"
got=$(rest_post "$PRIYA" "pt_packages?select=sessions_purchased" "$PKG_OVERRIDE")
assert_contains "an explicit sessions_purchased overrides the derived value (25, not 24)" '"sessions_purchased":25' "$got"

# --- duration_months sanity bound 1..36 (migration 20260829099500) ---
PKG_DUR_HI="{\"organization_id\":\"$ORG_IRON\",\"member_id\":\"$ASHA\",\"coach_id\":\"$GIRISH_UID\",\"goal\":\"fat_loss\",\"duration_months\":40,\"sessions_per_month\":2,\"price\":4321.40}"
assert_equals "pt_package with duration_months = 40 is rejected (>36)" "400" "$(rest_post_status "$PRIYA" "pt_packages" "$PKG_DUR_HI")"
PKG_DUR_LO="{\"organization_id\":\"$ORG_IRON\",\"member_id\":\"$ASHA\",\"coach_id\":\"$GIRISH_UID\",\"goal\":\"fat_loss\",\"duration_months\":0,\"sessions_per_month\":2,\"price\":4321.41}"
assert_equals "pt_package with duration_months = 0 is rejected (<1)" "400" "$(rest_post_status "$PRIYA" "pt_packages" "$PKG_DUR_LO")"
PKG_DUR_MAX="{\"organization_id\":\"$ORG_IRON\",\"member_id\":\"$ASHA\",\"coach_id\":\"$GIRISH_UID\",\"goal\":\"fat_loss\",\"duration_months\":36,\"sessions_per_month\":1,\"price\":4321.42}"
got=$(rest_post "$PRIYA" "pt_packages?select=duration_months,sessions_purchased" "$PKG_DUR_MAX")
assert_contains "pt_package with duration_months = 36 is accepted (boundary)" '"duration_months":36' "$got"

# --- cross-org isolation with a valid coach session ---
assert_equals "Hema (FlexFit coach) reading Iron pt_packages -> 0"    "0" "$(count_rows "$(rest "$HEMA" "pt_packages?organization_id=eq.$ORG_IRON&select=id")")"
assert_equals "Hema reading Iron training_notes -> 0"                 "0" "$(count_rows "$(rest "$HEMA" "training_notes?organization_id=eq.$ORG_IRON&select=id")")"
assert_equals "Hema reading Iron members -> 0"                        "0" "$(count_rows "$(rest "$HEMA" "members?organization_id=eq.$ORG_IRON&select=id")")"
assert_equals "Farah reading FlexFit pt_packages -> 0"               "0" "$(count_rows "$(rest "$FARAH" "pt_packages?organization_id=eq.$ORG_FLEX&select=id")")"

# --- member with no package: no coaching data anywhere, cleanly ---
assert_equals "owner: pt_packages for Bharat -> 0"        "0" "$(count_rows "$(rest "$RAVI" "pt_packages?member_id=eq.$BHARAT&select=id")")"
assert_equals "owner: training_notes for Bharat -> 0"     "0" "$(count_rows "$(rest "$RAVI" "training_notes?member_id=eq.$BHARAT&select=id")")"
assert_equals "owner: body_measurements for Bharat -> 0"  "0" "$(count_rows "$(rest "$RAVI" "body_measurements?member_id=eq.$BHARAT&select=id")")"
assert_equals "owner reads on an unpackaged member are 200, not errors" "200" "$(rest_status "$RAVI" "training_notes?member_id=eq.$BHARAT&select=id")"

# ---------------------------------------------------------------------------
# 9. Unified session write — log_session RPC, session-count trigger, paginated
#    session history
# ---------------------------------------------------------------------------
printf '\n%s-- unified session: log_session + session count + history --%s\n' "$B" "$N"

RITU=80000000-0000-0000-0000-000000000004        # Farah -> Ritu, pkg f1 (5 purchased), from arrange_fixtures
AJAY=80000000-0000-0000-0000-000000000005        # Farah -> Ajay, pkg f3 (4/5), from arrange_fixtures
PKG_PAGE=9c000000-0000-0000-0000-0000000000f1
PKG_RACE=9c000000-0000-0000-0000-0000000000f3

# --- who may NOT call log_session (package f1 still untouched at 0/5) ---
assert_equals "front_desk cannot log_session" "403" \
  "$(rest_rpc_status "$PRIYA" log_session "{\"p_member_id\":\"$RITU\",\"p_pt_package_id\":\"$PKG_PAGE\",\"p_note_text\":\"rls-test fd\"}")"
assert_equals "a coach cannot log_session against another coach's package" "403" \
  "$(rest_rpc_status "$GIRISH" log_session "{\"p_member_id\":\"$RITU\",\"p_pt_package_id\":\"$PKG_PAGE\",\"p_note_text\":\"rls-test xcoach\"}")"
assert_equals "a coach in another org cannot log_session here" "403" \
  "$(rest_rpc_status "$HEMA" log_session "{\"p_member_id\":\"$RITU\",\"p_pt_package_id\":\"$PKG_PAGE\",\"p_note_text\":\"rls-test xorg\"}")"
assert_equals "log_session with weight but no height is rejected (both-or-neither)" "400" \
  "$(rest_rpc_status "$FARAH" log_session "{\"p_member_id\":\"$RITU\",\"p_pt_package_id\":\"$PKG_PAGE\",\"p_note_text\":\"rls-test half\",\"p_weight_kg\":70}")"
assert_equals "  ...and none of those rejected calls advanced the session count" "0" \
  "$(sql "select sessions_used from pt_packages where id='$PKG_PAGE'")"

# --- session with note only ---
got=$(rest_rpc "$FARAH" log_session "{\"p_member_id\":\"$RITU\",\"p_pt_package_id\":\"$PKG_PAGE\",\"p_note_text\":\"rls-test S1\",\"p_session_date\":\"2026-01-01\"}")
assert_contains "log_session (note only) returns a training_note_id"      '"training_note_id":"' "$got"
assert_contains "log_session (note only) leaves body_measurement_id null"  '"body_measurement_id":null' "$got"
assert_contains "log_session (note only) advances sessions_used to 1"      '"sessions_used":1' "$got"

# --- session with note + linked measurement ---
got=$(rest_rpc "$FARAH" log_session "{\"p_member_id\":\"$RITU\",\"p_pt_package_id\":\"$PKG_PAGE\",\"p_note_text\":\"rls-test S2\",\"p_session_date\":\"2026-01-02\",\"p_weight_kg\":80.00,\"p_height_cm\":178}")
assert_contains "log_session (note + measurement) returns a body_measurement_id" '"body_measurement_id":"' "$got"
assert_contains "log_session (note + measurement) advances sessions_used to 2"    '"sessions_used":2' "$got"
s2_note=$(printf '%s' "$got" | sed -n 's/.*"training_note_id":"\([^"]*\)".*/\1/p')
got=$(rest "$FARAH" "body_measurements?training_note_id=eq.$s2_note&select=weight_kg,bmi,member_id")
assert_contains "the linked measurement is stored against the right member" "\"member_id\":\"$RITU\"" "$got"
assert_contains "the linked measurement's generated BMI is correct (80.0/178 -> 25.2)" '"bmi":25.2' "$got"

# --- three more sessions bring it to the purchased count -> auto-complete ---
rest_rpc "$FARAH" log_session "{\"p_member_id\":\"$RITU\",\"p_pt_package_id\":\"$PKG_PAGE\",\"p_note_text\":\"rls-test S3\"}" >/dev/null
rest_rpc "$FARAH" log_session "{\"p_member_id\":\"$RITU\",\"p_pt_package_id\":\"$PKG_PAGE\",\"p_note_text\":\"rls-test S4\",\"p_weight_kg\":79.50,\"p_height_cm\":178}" >/dev/null
got=$(rest_rpc "$FARAH" log_session "{\"p_member_id\":\"$RITU\",\"p_pt_package_id\":\"$PKG_PAGE\",\"p_note_text\":\"rls-test S5\"}")
assert_contains "the session that reaches sessions_purchased auto-completes the package" '"package_status":"completed"' "$got"
assert_contains "  ...with sessions_used == sessions_purchased"                          '"sessions_used":5' "$got"
assert_equals   "DB agrees the package is completed" "completed" "$(sql "select status from pt_packages where id='$PKG_PAGE'")"

# --- a completed package rejects a further session, and does not overshoot ---
assert_equals "log_session on the now-completed package is refused" "403" \
  "$(rest_rpc_status "$FARAH" log_session "{\"p_member_id\":\"$RITU\",\"p_pt_package_id\":\"$PKG_PAGE\",\"p_note_text\":\"rls-test S6 overflow\"}")"
assert_equals "  ...sessions_used stayed at the purchased count" "5" "$(sql "select sessions_used from pt_packages where id='$PKG_PAGE'")"

# --- concurrent sessions at the boundary must not overshoot (pkg f3 at 4/5) ---
race_codes=$(for i in 1 2 3 4 5; do
  rest_rpc_status "$FARAH" log_session "{\"p_member_id\":\"$AJAY\",\"p_pt_package_id\":\"$PKG_RACE\",\"p_note_text\":\"rls-test race $i\"}" &
done; wait)
race_ok=$(printf '%s\n' "$race_codes" | grep -c '^20')
race_bad=$(printf '%s\n' "$race_codes" | grep -cE '^40[0-9]')
assert_equals "exactly ONE of 5 concurrent boundary sessions succeeds" "1" "$race_ok"
assert_equals "the other four are cleanly refused (4xx, no 5xx)"       "4" "$race_bad"
assert_equals "sessions_used lands exactly on the purchased count"     "5" "$(sql "select sessions_used from pt_packages where id='$PKG_RACE'")"
assert_equals "the race package is completed"                          "completed" "$(sql "select status from pt_packages where id='$PKG_RACE'")"
assert_equals "exactly one race note actually persisted"              "1" "$(sql "select count(*) from training_notes where pt_package_id='$PKG_RACE' and note_text like 'rls-test race%'")"

# --- paginated session history: training_notes + optional linked measurement,
#     session_date desc, keyed tiebreak on created_at then id ---
PGSEL="member_id=eq.$RITU&select=note_text,session_date,body_measurements(weight_kg,bmi)&order=session_date.desc,created_at.desc,id.desc"
# full desc order is S5, S4, S3 (all CURRENT_DATE, newest created_at first), then S2 (2026-01-02), S1 (2026-01-01)
assert_equals "history page 1 range is 0-1 of 5"  "0-1/5" "$(rest_range "$FARAH" "training_notes?$PGSEL&limit=2&offset=0")"
assert_equals "history page 2 range is 2-3 of 5"  "2-3/5" "$(rest_range "$FARAH" "training_notes?$PGSEL&limit=2&offset=2")"
assert_equals "history page 3 range is 4-4 of 5"  "4-4/5" "$(rest_range "$FARAH" "training_notes?$PGSEL&limit=2&offset=4")"

p1=$(rest "$FARAH" "training_notes?$PGSEL&limit=2&offset=0")
assert_contains "page 1 holds the two newest sessions (S5, S4)" "rls-test S5" "$p1"
assert_contains "page 1 holds S4"                               "rls-test S4" "$p1"
assert_not_contains "page 1 does NOT spill into S3"             "rls-test S3" "$p1"
case "$p1" in
  *'"rls-test S5"'*'"rls-test S4"'*) ok "page 1 rows are ordered newest-first (S5 before S4)" ;;
  *) bad "page 1 ordering" "S5 before S4" "$p1" ;;
esac
assert_contains "S4's linked weigh-in is embedded (bmi 25.10 for 79.50/178)" '25.10' "$p1"
case "$p1" in
  *'"rls-test S5"'*'"body_measurements":[]'*) ok "S5 (note only) shows an empty measurement embed" ;;
  *) bad "S5 empty measurement embed" 'S5 then body_measurements:[]' "$p1" ;;
esac

p3=$(rest "$FARAH" "training_notes?$PGSEL&limit=2&offset=4")
assert_contains "page 3 holds the oldest session (S1)"          "rls-test S1" "$p3"
assert_not_contains "page 3 does NOT still contain S2"          "rls-test S2" "$p3"

# history query is assignment-scoped like everything else
assert_equals "another coach sees 0 of Ritu's session history"        "0" \
  "$(count_rows "$(rest "$GIRISH" "training_notes?member_id=eq.$RITU&select=id")")"
assert_equals "a coach in another org sees 0 of Ritu's session history" "0" \
  "$(count_rows "$(rest "$HEMA" "training_notes?member_id=eq.$RITU&select=id")")"
assert_equals "front_desk sees 0 of Ritu's session history"           "0" \
  "$(count_rows "$(rest "$PRIYA" "training_notes?member_id=eq.$RITU&select=id")")"
# ...but the assigned coach keeps it after the package completed (093000/097000 history rule)
hist_n=$(count_rows "$(rest "$FARAH" "training_notes?member_id=eq.$RITU&select=id")")
if [ "$hist_n" -eq 5 ] 2>/dev/null; then
  ok "the assigned coach still reads all 5 sessions after the package completed"
else
  bad "assigned coach reads completed-package history" "5" "$hist_n"
fi
assert_equals "owner reads the same completed-package history org-wide" "5" \
  "$(count_rows "$(rest "$RAVI" "training_notes?member_id=eq.$RITU&select=id")")"

# cross-org: the new note<->measurement linkage cannot straddle orgs
xo_note=$(sql "select id from training_notes where member_id='$RITU' and note_text='rls-test S1'")
assert_equals "a measurement cannot link to a note from a different member (validate trigger)" "400" \
  "$(rest_post_status "$FARAH" "body_measurements" "{\"organization_id\":\"$ORG_IRON\",\"member_id\":\"$ASHA\",\"recorded_by\":\"c0ac0000-0000-0000-0000-000000000001\",\"weight_kg\":77.77,\"height_cm\":180,\"training_note_id\":\"$xo_note\"}")"

# ---------------------------------------------------------------------------
# 10. membership_plans CRUD — owner/front_desk write, everyone else read-only
#     (migration 20260829100000)
# ---------------------------------------------------------------------------
printf '\n%s-- membership_plans CRUD --%s\n' "$B" "$N"

assert_equals "owner CAN create a plan" "201" \
  "$(rest_post_status "$RAVI"  "membership_plans" "{\"organization_id\":\"$ORG_IRON\",\"name\":\"rls-test plan A\",\"amount\":999.00}")"
assert_equals "front_desk CAN create a plan" "201" \
  "$(rest_post_status "$PRIYA" "membership_plans" "{\"organization_id\":\"$ORG_IRON\",\"name\":\"rls-test plan B\",\"amount\":1499.00}")"
assert_equals "a coach CANNOT create a plan" "403" \
  "$(rest_post_status "$FARAH" "membership_plans" "{\"organization_id\":\"$ORG_IRON\",\"name\":\"rls-test plan C\",\"amount\":100.00}")"
assert_equals "owner of Iron CANNOT create a plan for FlexFit (cross-org)" "403" \
  "$(rest_post_status "$RAVI" "membership_plans" "{\"organization_id\":\"$ORG_FLEX\",\"name\":\"rls-test plan X\",\"amount\":500.00}")"
assert_equals "an absurd amount is rejected (sanity bound)" "400" \
  "$(rest_post_status "$RAVI" "membership_plans" "{\"organization_id\":\"$ORG_IRON\",\"name\":\"rls-test plan huge\",\"amount\":9999999.00}")"
assert_equals "a negative amount is rejected" "400" \
  "$(rest_post_status "$RAVI" "membership_plans" "{\"organization_id\":\"$ORG_IRON\",\"name\":\"rls-test plan neg\",\"amount\":-5.00}")"

plan_id=$(sql "select id from membership_plans where name='rls-test plan A'")
assert_equals "owner CAN rename + reprice a plan" "200" \
  "$(rest_patch_status "$RAVI" "membership_plans?id=eq.$plan_id" '{"name":"rls-test plan A2","amount":1250.00}')"
assert_equals "owner CAN soft-deactivate a plan (active=false, no hard delete)" "200" \
  "$(rest_patch_status "$RAVI" "membership_plans?id=eq.$plan_id" '{"active":false}')"
assert_equals "a coach CANNOT edit a plan" "403" \
  "$(rest_patch_status "$FARAH" "membership_plans?id=eq.$plan_id" '{"amount":1.00}')"

got=$(rest "$FARAH" "membership_plans?organization_id=eq.$ORG_IRON&select=id,name")
assert_contains "a coach still reads the plan catalogue (USING unchanged)" "rls-test plan A2" "$got"

assert_equals "anon CANNOT create a plan" "401" \
  "$(rest_post_status "$ANON_KEY" "membership_plans" "{\"organization_id\":\"$ORG_IRON\",\"name\":\"rls-test plan anon\",\"amount\":1.00}")"

# ---------------------------------------------------------------------------
# 11. PT-package payments + revenue-by-source + attention view
#     (migrations 20260829101000 / 101500 / 102000)
# ---------------------------------------------------------------------------
printf '\n%s-- PT payments, revenue split, attention view --%s\n' "$B" "$N"

# --- selling a PT package records a payment (trigger); owner sees it, front_desk does not ---
got=$(rest "$RAVI" "payments?pt_package_id=eq.9c000000-0000-0000-0000-000000000001&select=amount,status,membership_id")
assert_contains "owner sees the auto-recorded PT payment"          '"amount":12000' "$got"
assert_contains "  ...as a manual payment"                         '"status":"manual"' "$got"
assert_contains "  ...with membership_id null (XOR)"               '"membership_id":null' "$got"
assert_equals   "front_desk sees zero PT payments (owner-only, unchanged)" "0" \
  "$(count_rows "$(rest "$PRIYA" "payments?pt_package_id=eq.9c000000-0000-0000-0000-000000000001&select=id")")"

# --- XOR constraint (DB-level; no authenticated INSERT grant on payments, so
#     exercised via psql — the trigger/seed/service_role paths all hit it) ---
xor_both=$(docker exec "$DB_CONTAINER" psql -U postgres -d postgres -tAc "INSERT INTO payments (organization_id, membership_id, pt_package_id, amount, provider, status, idempotency_key) VALUES ('$ORG_IRON','f1111111-1111-1111-1111-111111111111','9c000000-0000-0000-0000-000000000001',1,'x','manual','rls-test-xor-both');" 2>&1)
assert_contains "a payment naming BOTH subjects violates payments_subject_xor"    "payments_subject_xor" "$xor_both"
xor_none=$(docker exec "$DB_CONTAINER" psql -U postgres -d postgres -tAc "INSERT INTO payments (organization_id, amount, provider, status, idempotency_key) VALUES ('$ORG_IRON',1,'x','manual','rls-test-xor-none');" 2>&1)
assert_contains "a payment naming NEITHER subject violates payments_subject_xor"  "payments_subject_xor" "$xor_none"

# --- revenue by source: owner sees a membership + a pt_package line; they sum to the combined view ---
got=$(rest "$RAVI" "v_daily_revenue_by_source?organization_id=eq.$ORG_IRON&select=source,total")
assert_contains "owner's revenue breakout has a membership line"   '"source":"membership"' "$got"
assert_contains "owner's revenue breakout has a pt_package line"    '"source":"pt_package"' "$got"
assert_equals   "front_desk sees zero revenue rows (security_invoker -> payments RLS)" "[]" \
  "$(rest "$PRIYA" "v_daily_revenue_by_source?organization_id=eq.$ORG_IRON&select=total")"
by_source_sum=$(sql "select coalesce(sum(total),0)::int from v_daily_revenue_by_source where organization_id='$ORG_IRON'")
combined_sum=$(sql "select coalesce(sum(total),0)::int from v_daily_revenue where organization_id='$ORG_IRON'")
assert_equals "combined v_daily_revenue == sum of the by-source split" "$by_source_sum" "$combined_sum"

# --- v_pt_packages_attention: owner-only, flags the low-session fixture (f5) ---
got=$(rest "$RAVI" "v_pt_packages_attention?select=id,low_sessions,sessions_remaining,member_name")
assert_contains "owner sees the low-session package in the attention view" "9c000000-0000-0000-0000-0000000000f5" "$got"
assert_contains "  ...flagged low_sessions"                        '"low_sessions":true' "$got"
assert_contains "  ...with the member name joined in"              '"member_name":"Manoj Tiwari"' "$got"
assert_equals   "front_desk sees nothing in the attention view (owner-only)" "0" \
  "$(count_rows "$(rest "$PRIYA" "v_pt_packages_attention?select=id")")"
assert_equals   "a coach sees nothing in the attention view (owner-only)" "0" \
  "$(count_rows "$(rest "$FARAH" "v_pt_packages_attention?select=id")")"
assert_equals   "cross-org: FlexFit owner sees no Iron attention rows" "0" \
  "$(count_rows "$(rest "$SANJAY" "v_pt_packages_attention?select=id")")"

# --- v_members_pt_status: has_active_pt per member, RLS-scoped (20260829103000) ---
got=$(rest "$RAVI" "v_members_pt_status?organization_id=eq.$ORG_IRON&select=id,has_active_pt,active_pt_count")
assert_contains "owner: a member WITH an active package is flagged" \
  "\"id\":\"$ASHA\",\"has_active_pt\":true" "$got"
got2=$(rest "$RAVI" "v_members_pt_status?id=eq.$BHARAT&select=has_active_pt,active_pt_count")
assert_contains "owner: a member with NO package is has_active_pt:false" '"has_active_pt":false' "$got2"
assert_contains "  ...active_pt_count 0"                               '"active_pt_count":0' "$got2"
# a coach sees only assigned members, still with the right flag
got3=$(rest "$FARAH" "v_members_pt_status?select=id,has_active_pt")
assert_contains     "coach: assigned member flagged has_active_pt:true" "\"id\":\"$ASHA\",\"has_active_pt\":true" "$got3"
assert_not_contains "coach: an unassigned member is absent entirely"    "$BHARAT" "$got3"
# front_desk sees their location's members with the flag; owner-only PT rows still don't leak an unscoped count
assert_equals "front_desk reads v_members_pt_status: 200 not 403" "200" \
  "$(rest_status "$PRIYA" "v_members_pt_status?select=id&limit=1")"
# cross-org
assert_equals "cross-org: FlexFit owner sees no Iron members here" "0" \
  "$(count_rows "$(rest "$SANJAY" "v_members_pt_status?organization_id=eq.$ORG_IRON&select=id")")"

# ---------------------------------------------------------------------------
# 12. coaches_workload — client counts for the assign-a-coach decision
#     (migration 20260901091000)
# ---------------------------------------------------------------------------
printf '\n%s-- coaches_workload --%s\n' "$B" "$N"

# Readable by owner AND front_desk (front_desk assigns coaches).
assert_equals "owner reads coaches_workload: 200"      "200" "$(rest_status "$RAVI"  "coaches_workload?select=id")"
assert_equals "front_desk reads coaches_workload: 200" "200" "$(rest_status "$PRIYA" "coaches_workload?select=id")"

wl=$(rest "$RAVI" "coaches_workload?select=id,name,active_client_count,most_recent_session_date")
assert_contains "coaches_workload lists Farah" "\"id\":\"$FARAH_UID\"" "$wl"
assert_contains "coaches_workload lists Girish" "\"id\":\"$GIRISH_UID\"" "$wl"
assert_contains "Farah has a most_recent_session_date (she has notes)" "\"most_recent_session_date\":\"20" "$wl"

# active_client_count must equal the LIVE count of active packages for that
# coach, and completed packages must NOT be in it. Farah's seed set includes
# the COMPLETED Chitra package (9c..004) — proof there is one to exclude.
farah_wl=$(printf '%s' "$(rest "$RAVI" "coaches_workload?select=active_client_count&id=eq.$FARAH_UID")" | sed -n 's/.*"active_client_count":\([0-9]*\).*/\1/p')
farah_active=$(count_rows "$(rest "$RAVI" "pt_packages?coach_id=eq.$FARAH_UID&status=eq.active&select=id")")
farah_completed=$(count_rows "$(rest "$RAVI" "pt_packages?coach_id=eq.$FARAH_UID&status=eq.completed&select=id")")
assert_equals "coaches_workload count == live active-package count for Farah" "$farah_active" "$farah_wl"
if [ "${farah_completed:-0}" -ge 1 ] 2>/dev/null; then
  ok "Farah has >=1 completed package that coaches_workload correctly excludes"
else
  bad "a completed package exists to prove exclusion" ">=1" "$farah_completed"
fi

# Org scoping: an Iron owner never sees a FlexFit coach and vice-versa.
assert_not_contains "Iron owner's coaches_workload has no FlexFit coach (Hema)" \
  "c0ac0000-0000-0000-0000-000000000003" "$wl"
assert_equals "FlexFit owner's coaches_workload has zero Iron coaches" "0" \
  "$(count_rows "$(rest "$SANJAY" "coaches_workload?id=in.($FARAH_UID,$GIRISH_UID)&select=id")")"
assert_contains "FlexFit owner DOES see their own coach (Hema)" \
  "c0ac0000-0000-0000-0000-000000000003" "$(rest "$SANJAY" "coaches_workload?select=id")"

# ---------------------------------------------------------------------------
# 13. Suspended organization — every tenant table returns zero rows for an
#     ALREADY-OPEN session the moment status flips, and reactivating restores
#     it with no re-login. (migration 20260902090000, current_org_active() +
#     the org_not_suspended RESTRICTIVE policies)
# ---------------------------------------------------------------------------
printf '\n%s-- suspended organization freeze --%s\n' "$B" "$N"

# Baseline: SANJAY (FlexFit owner) and HEMA (FlexFit coach) see their data.
assert_equals "baseline: FlexFit owner sees >=1 member" "1" \
  "$([ "$(count_rows "$(rest "$SANJAY" "members?organization_id=eq.$ORG_FLEX&select=id&limit=1")")" -ge 1 ] && echo 1 || echo 0)"
assert_equals "baseline: FlexFit owner reads own org row: 200" "200" \
  "$(rest_status "$SANJAY" "organizations?id=eq.$ORG_FLEX&select=id")"

sql "UPDATE organizations SET status = 'suspended' WHERE id = '$ORG_FLEX'" >/dev/null

# SAME tokens, no refresh — the RESTRICTIVE gate re-reads status per query.
for tbl in members memberships payments attendance whatsapp_messages membership_plans pt_packages; do
  assert_equals "suspended: FlexFit owner sees 0 rows in $tbl" "0" \
    "$(count_rows "$(rest "$SANJAY" "$tbl?organization_id=eq.$ORG_FLEX&select=id")")"
done
assert_equals "suspended: FlexFit owner can't even read the organizations row" "0" \
  "$(count_rows "$(rest "$SANJAY" "organizations?id=eq.$ORG_FLEX&select=id")")"
assert_equals "suspended: FlexFit coach sees 0 members" "0" \
  "$(count_rows "$(rest "$HEMA" "members?select=id")")"
assert_equals "suspended: FlexFit owner INSERT into members is blocked" "403" \
  "$(rest_post_status "$SANJAY" "members" "{\"organization_id\":\"$ORG_FLEX\",\"location_id\":\"$LOC_FLEX\",\"name\":\"Nope\",\"phone\":\"919000099999\"}")"

# Iron is untouched — suspension is per-tenant.
assert_equals "suspended FlexFit does NOT affect Iron: owner still sees members" "1" \
  "$([ "$(count_rows "$(rest "$RAVI" "members?organization_id=eq.$ORG_IRON&select=id&limit=1")")" -ge 1 ] && echo 1 || echo 0)"

sql "UPDATE organizations SET status = 'active' WHERE id = '$ORG_FLEX'" >/dev/null

# Same token again — full access back, no re-login.
assert_equals "reactivated: FlexFit owner sees members again" "1" \
  "$([ "$(count_rows "$(rest "$SANJAY" "members?organization_id=eq.$ORG_FLEX&select=id&limit=1")")" -ge 1 ] && echo 1 || echo 0)"
assert_equals "reactivated: FlexFit owner reads own org row again: 200" "200" \
  "$(rest_status "$SANJAY" "organizations?id=eq.$ORG_FLEX&select=id")"

# ---------------------------------------------------------------------------
# 14. v_payments_ledger — the deliberate front_desk-read reversal
#     (migration 20260903090000). Expected counts are computed FRESH from the
#     DB right here rather than hardcoded from the seed, because by this point
#     in the suite earlier sections (8-11's coaching fixtures especially) have
#     already created additional payments via the pt_packages_record_payment
#     trigger — the view is cross-checked against ground truth, not a stale
#     literal. arrange_fixtures() at the top added exactly ONE payment at HSR
#     Layout (PAYMENT_LOC2, status success, type membership) — the
#     front_desk-exclusion proof, since Priya is at Indiranagar.
# ---------------------------------------------------------------------------
printf '\n%s-- v_payments_ledger (owner org-wide, front_desk location-scoped) --%s\n' "$B" "$N"

IRON_TOTAL=$(sql "select count(*) from payments where organization_id='$ORG_IRON';")
IRON_INDIRANAGAR=$(sql "select count(*) from payments p
  left join memberships ms on ms.id=p.membership_id
  left join pt_packages pk on pk.id=p.pt_package_id
  join members m on m.id = coalesce(ms.member_id, pk.member_id)
  where p.organization_id='$ORG_IRON' and m.location_id='$LOC_IRON';")
IRON_PT=$(sql "select count(*) from payments where organization_id='$ORG_IRON' and pt_package_id is not null;")
IRON_MEMBERSHIP=$(sql "select count(*) from payments where organization_id='$ORG_IRON' and membership_id is not null;")
IRON_INDIRANAGAR_PT=$(sql "select count(*) from payments p
  join pt_packages pk on pk.id=p.pt_package_id join members m on m.id=pk.member_id
  where p.organization_id='$ORG_IRON' and m.location_id='$LOC_IRON';")
IRON_SUCCESS=$(sql "select count(*) from payments where organization_id='$ORG_IRON' and status='success';")
IRON_FAILED=$(sql "select count(*) from payments where organization_id='$ORG_IRON' and status='failed';")

assert_equals "owner sees ALL Iron payments (ground truth: $IRON_TOTAL)" "$IRON_TOTAL" \
  "$(count_rows "$(rest "$RAVI" "v_payments_ledger?organization_id=eq.$ORG_IRON&select=id")")"
assert_equals "front_desk @ Indiranagar sees only their location's payments" "$IRON_INDIRANAGAR" \
  "$(count_rows "$(rest "$PRIYA" "v_payments_ledger?organization_id=eq.$ORG_IRON&select=id")")"
assert_not_contains "front_desk does NOT see the HSR Layout payment" "$PAYMENT_LOC2" \
  "$(rest "$PRIYA" "v_payments_ledger?select=id")"
assert_contains "owner DOES see the HSR Layout payment" "$PAYMENT_LOC2" \
  "$(rest "$RAVI" "v_payments_ledger?select=id")"
assert_equals "a coach session has no path to the ledger at all" "0" \
  "$(count_rows "$(rest "$FARAH" "v_payments_ledger?select=id")")"
assert_equals "front_desk sees no OTHER location's payments in the ledger (base-table probe)" "0" \
  "$(count_rows "$(rest "$PRIYA" "payments?organization_id=eq.$ORG_IRON&select=id")")"

# --- payment_type: membership vs personal_training, derived from the XOR FK ---
assert_equals "owner: personal_training count matches pt_package_id IS NOT NULL" "$IRON_PT" \
  "$(count_rows "$(rest "$RAVI" "v_payments_ledger?organization_id=eq.$ORG_IRON&payment_type=eq.personal_training&select=id")")"
assert_equals "owner: membership count matches membership_id IS NOT NULL" "$IRON_MEMBERSHIP" \
  "$(count_rows "$(rest "$RAVI" "v_payments_ledger?organization_id=eq.$ORG_IRON&payment_type=eq.membership&select=id")")"
assert_equals "front_desk: personal_training at their own location" "$IRON_INDIRANAGAR_PT" \
  "$(count_rows "$(rest "$PRIYA" "v_payments_ledger?payment_type=eq.personal_training&select=id")")"

# --- status filter ---
assert_equals "owner: status=success matches ground truth" "$IRON_SUCCESS" \
  "$(count_rows "$(rest "$RAVI" "v_payments_ledger?organization_id=eq.$ORG_IRON&status=eq.success&select=id")")"
assert_equals "owner: status=failed matches ground truth" "$IRON_FAILED" \
  "$(count_rows "$(rest "$RAVI" "v_payments_ledger?organization_id=eq.$ORG_IRON&status=eq.failed&select=id")")"

# --- location filter (multi-branch owner narrowing to one branch) ---
assert_equals "owner: location_id filter to HSR Layout == 1 (just the fixture)" "1" \
  "$(count_rows "$(rest "$RAVI" "v_payments_ledger?location_id=eq.$LOC_IRON_2&select=id")")"

# --- date range filter — the fixture payment reconciled at now() ---
TODAY_UTC=$(sql "select to_char(now(),'YYYY-MM-DD');")
TOMORROW_UTC=$(sql "select to_char(now() + interval '1 day','YYYY-MM-DD');")
assert_contains "date range: gte today includes the just-reconciled fixture" "$PAYMENT_LOC2" \
  "$(rest "$RAVI" "v_payments_ledger?transaction_date=gte.${TODAY_UTC}&select=id")"
assert_not_contains "date range: gte tomorrow excludes it" "$PAYMENT_LOC2" \
  "$(rest "$RAVI" "v_payments_ledger?transaction_date=gte.${TOMORROW_UTC}&select=id")"

# --- pagination: HTTP Range + Prefer: count=exact, the wire shape of
#     supabase-js .range(), same mechanism coachWrites.getSessionHistory()
#     already uses. Deterministic order is required for stable pages. ---
ORDERED="v_payments_ledger?organization_id=eq.$ORG_IRON&order=transaction_date.desc,id.desc&select=id"
range1=$(rest_page_range "$RAVI" "$ORDERED" "0-4")
assert_equals "page 1 (items 0-4) Content-Range reports the true total" "0-4/$IRON_TOTAL" "$range1"
page1_ids=$(rest_page "$RAVI" "$ORDERED" "0-4")
page2_ids=$(rest_page "$RAVI" "$ORDERED" "5-9")
assert_equals "page 1 returns exactly 5 rows" "5" "$(count_rows "$page1_ids")"
assert_equals "page 2 returns exactly 5 rows" "5" "$(count_rows "$page2_ids")"
overlap=$(comm -12 \
  <(printf '%s' "$page1_ids" | grep -o '"id":"[^"]*"' | sort) \
  <(printf '%s' "$page2_ids" | grep -o '"id":"[^"]*"' | sort) | wc -l | tr -d ' ')
assert_equals "page 1 and page 2 are disjoint (no dupes, no gaps in ordering)" "0" "$overlap"
LAST_START=$((IRON_TOTAL - 2))
last_range=$(rest_page_range "$RAVI" "$ORDERED" "${LAST_START}-9999")
assert_equals "a final short page still reports the true total, not the page size" \
  "${LAST_START}-$((IRON_TOTAL - 1))/$IRON_TOTAL" "$last_range"

# --- cross-org isolation ---
assert_equals "FlexFit owner sees ZERO Iron payments" "0" \
  "$(count_rows "$(rest "$SANJAY" "v_payments_ledger?organization_id=eq.$ORG_IRON&select=id")")"
assert_not_contains "FlexFit owner's own ledger never contains an Iron payment id" "$PAYMENT_LOC2" \
  "$(rest "$SANJAY" "v_payments_ledger?select=id")"

# --- the reversal is READ only: front_desk still cannot write a payment ---
assert_equals "front_desk INSERT into payments is still blocked (no grant)" "403" \
  "$(rest_post_status "$PRIYA" "payments" "{\"organization_id\":\"$ORG_IRON\",\"membership_id\":\"$MEMBERSHIP_LOC2\",\"amount\":1,\"provider\":\"manual\",\"status\":\"success\",\"idempotency_key\":\"rls-test-frontdesk-write-attempt\"}")"

# --- and it did not leak into the revenue dashboards (the exact regression
#     this design avoids — see the migration's DESIGN NOTE) ---
assert_equals "front_desk STILL sees zero rows in v_daily_revenue_by_source" "0" \
  "$(count_rows "$(rest "$PRIYA" "v_daily_revenue_by_source?organization_id=eq.$ORG_IRON&select=total")")"
assert_equals "front_desk STILL sees zero rows in v_daily_revenue" "0" \
  "$(count_rows "$(rest "$PRIYA" "v_daily_revenue?organization_id=eq.$ORG_IRON&select=total")")"

# ---------------------------------------------------------------------------
# 15. Membership freezing — freeze_membership() / unfreeze_membership() RPCs,
#     membership_freezes RLS. (migration 20260904090000). Auto-unfreeze via
#     mark-overdue and the frozen check-in reply are covered in their own
#     function test.sh suites, not here.
# ---------------------------------------------------------------------------
printf '\n%s-- membership freezing --%s\n' "$B" "$N"

ASHA_MEMBERSHIP=f1111111-1111-1111-1111-111111111111        # Asha, Indiranagar, active
BHARAT_MEMBERSHIP=f2222222-2222-2222-2222-222222222222       # Bharat, Indiranagar, past_due
CANCELLED_MEMBERSHIP=70000000-0000-0000-0000-000000000006    # Pooja, Indiranagar, cancelled
DEEPAK_MEMBERSHIP=70000000-0000-0000-0000-000000000001       # Deepak, Indiranagar, active
EXPIRED_MEMBERSHIP=0daded00-1111-0000-0000-0000000000e1      # throwaway, this section only
ELAPSED_MEMBERSHIP=0daded00-1111-0000-0000-0000000000e2      # throwaway, this section only

ASHA_BEFORE=$(sql "select current_period_end from memberships where id='$ASHA_MEMBERSHIP';")

# --- front_desk (Priya, Indiranagar) freezes Asha's own-location membership ---
got=$(rest_rpc "$PRIYA" "freeze_membership" "{\"p_membership_id\":\"$ASHA_MEMBERSHIP\",\"p_days\":30,\"p_reason\":\"rls-test freeze\"}")
assert_contains "front_desk freezes an own-location membership -> ok" '"status":"frozen"' "$got"
assert_contains "  ...frozen_until is frozen_from + 30"            "\"days\":30" "$got"
FREEZE_ID=$(printf '%s' "$got" | sed -n 's/.*"freeze_id":"\([^"]*\)".*/\1/p')
assert_equals "memberships.status flipped to frozen" "frozen" "$(sql "select status from memberships where id='$ASHA_MEMBERSHIP';")"
assert_equals "current_period_end UNCHANGED while frozen (requirement 2)" "$ASHA_BEFORE" \
  "$(sql "select current_period_end from memberships where id='$ASHA_MEMBERSHIP';")"

# --- membership_freezes RLS: owner org-wide, front_desk own-location, cross-org zero ---
assert_contains "front_desk (own location) can read the freeze row" "$FREEZE_ID" \
  "$(rest "$PRIYA" "membership_freezes?id=eq.$FREEZE_ID&select=id,reason")"
assert_contains "  ...with the reason preserved" '"reason":"rls-test freeze"' \
  "$(rest "$PRIYA" "membership_freezes?id=eq.$FREEZE_ID&select=reason")"
assert_contains "owner can also read it (org-wide)" "$FREEZE_ID" \
  "$(rest "$RAVI" "membership_freezes?id=eq.$FREEZE_ID&select=id")"
assert_equals   "FlexFit owner reads ZERO rows for it (cross-org)" "0" \
  "$(count_rows "$(rest "$SANJAY" "membership_freezes?id=eq.$FREEZE_ID&select=id")")"

# --- can't freeze an already-frozen membership ---
assert_contains "double-freeze -> membership_already_frozen" "membership_already_frozen" \
  "$(rest_rpc "$RAVI" "freeze_membership" "{\"p_membership_id\":\"$ASHA_MEMBERSHIP\",\"p_days\":5}")"
assert_equals   "  ...400, not 200" "400" \
  "$(rest_rpc_status "$RAVI" "freeze_membership" "{\"p_membership_id\":\"$ASHA_MEMBERSHIP\",\"p_days\":5}")"

# --- can't freeze past_due / cancelled / expired — distinct errors each ---
assert_contains "past_due membership -> membership_past_due" "membership_past_due" \
  "$(rest_rpc "$RAVI" "freeze_membership" "{\"p_membership_id\":\"$BHARAT_MEMBERSHIP\",\"p_days\":5}")"
assert_contains "cancelled membership -> membership_cancelled" "membership_cancelled" \
  "$(rest_rpc "$RAVI" "freeze_membership" "{\"p_membership_id\":\"$CANCELLED_MEMBERSHIP\",\"p_days\":5}")"

sql "insert into memberships (id, organization_id, member_id, plan_id, status, start_date, current_period_end)
     values ('$EXPIRED_MEMBERSHIP', '$ORG_IRON', '$ASHA', 'cccccccc-cccc-cccc-cccc-cccccccccccc',
             'expired', CURRENT_DATE - 60, CURRENT_DATE - 30);" >/dev/null
assert_contains "expired membership -> membership_expired" "membership_expired" \
  "$(rest_rpc "$RAVI" "freeze_membership" "{\"p_membership_id\":\"$EXPIRED_MEMBERSHIP\",\"p_days\":5}")"

# --- days out of bounds ---
assert_contains "days=0 -> days_invalid"   "days_invalid" \
  "$(rest_rpc "$RAVI" "freeze_membership" "{\"p_membership_id\":\"$DEEPAK_MEMBERSHIP\",\"p_days\":0}")"
assert_contains "days=366 -> days_invalid" "days_invalid" \
  "$(rest_rpc "$RAVI" "freeze_membership" "{\"p_membership_id\":\"$DEEPAK_MEMBERSHIP\",\"p_days\":366}")"

# --- role: a coach cannot freeze anything, regardless of the target ---
assert_contains "coach -> not_authorized" "not_authorized" \
  "$(rest_rpc "$FARAH" "freeze_membership" "{\"p_membership_id\":\"$DEEPAK_MEMBERSHIP\",\"p_days\":5}")"
assert_equals   "  ...403" "403" \
  "$(rest_rpc_status "$FARAH" "freeze_membership" "{\"p_membership_id\":\"$DEEPAK_MEMBERSHIP\",\"p_days\":5}")"

# --- cross-org: FlexFit owner cannot freeze an Iron membership ---
assert_contains "cross-org freeze attempt -> membership_not_found" "membership_not_found" \
  "$(rest_rpc "$SANJAY" "freeze_membership" "{\"p_membership_id\":\"$DEEPAK_MEMBERSHIP\",\"p_days\":5}")"

# --- cross-location: front_desk (Indiranagar) cannot freeze HSR Layout's
#     membership; owner CAN (org-wide) ---
assert_contains "front_desk, wrong location -> membership_not_found" "membership_not_found" \
  "$(rest_rpc "$PRIYA" "freeze_membership" "{\"p_membership_id\":\"$MEMBERSHIP_LOC2\",\"p_days\":5}")"
got=$(rest_rpc "$RAVI" "freeze_membership" "{\"p_membership_id\":\"$MEMBERSHIP_LOC2\",\"p_days\":5}")
assert_contains "owner CAN freeze a different branch's membership" '"status":"frozen"' "$got"
# unfreeze it same-day (0 elapsed) so the throwaway fixture round-trips cleanly
rest_rpc "$RAVI" "unfreeze_membership" "{\"p_membership_id\":\"$MEMBERSHIP_LOC2\"}" >/dev/null

# --- manual EARLY unfreeze: shift by ACTUAL elapsed days, not the requested
#     duration (requirement 5). Freeze row inserted directly with a backdated
#     frozen_from — membership_freezes_dates_consistent forces frozen_until to
#     match, so this is the only way to simulate elapsed time in a live test. ---
sql "insert into memberships (id, organization_id, member_id, plan_id, status, start_date, current_period_end)
     values ('$ELAPSED_MEMBERSHIP', '$ORG_IRON', '$ASHA', 'cccccccc-cccc-cccc-cccc-cccccccccccc',
             'frozen', CURRENT_DATE - 90, CURRENT_DATE + 10);
     insert into membership_freezes (organization_id, membership_id, frozen_from, frozen_until, days, created_by)
     values ('$ORG_IRON', '$ELAPSED_MEMBERSHIP', CURRENT_DATE - 5, (CURRENT_DATE - 5) + 30, 30,
             (select id from users where phone='919000000001' and organization_id='$ORG_IRON'));" >/dev/null
got=$(rest_rpc "$PRIYA" "unfreeze_membership" "{\"p_membership_id\":\"$ELAPSED_MEMBERSHIP\"}")
assert_contains "early unfreeze reports days_frozen=5 (actual), not 30 (requested)" '"days_frozen":5' "$got"
assert_equals   "  ...current_period_end shifted by +5, not +30" "$(sql "select (CURRENT_DATE + 15)::text;")" \
  "$(sql "select current_period_end from memberships where id='$ELAPSED_MEMBERSHIP';")"
assert_equals   "  ...status back to active" "active" "$(sql "select status from memberships where id='$ELAPSED_MEMBERSHIP';")"
assert_equals   "  ...reactivated_at is set (manual early end)" "t" \
  "$(sql "select (reactivated_at is not null) from membership_freezes where membership_id='$ELAPSED_MEMBERSHIP';")"

# --- can't unfreeze a membership that isn't frozen ---
assert_contains "unfreezing an active membership -> membership_not_frozen" "membership_not_frozen" \
  "$(rest_rpc "$RAVI" "unfreeze_membership" "{\"p_membership_id\":\"$DEEPAK_MEMBERSHIP\"}")"

# --- suspended org: the freeze/unfreeze RPCs are gated exactly like every
#     other write (org_not_suspended, 20260902090000) ---
sql "UPDATE organizations SET status = 'suspended' WHERE id = '$ORG_IRON'" >/dev/null
assert_contains "suspended org blocks freeze_membership" "organization_suspended" \
  "$(rest_rpc "$RAVI" "freeze_membership" "{\"p_membership_id\":\"$DEEPAK_MEMBERSHIP\",\"p_days\":5}")"
sql "UPDATE organizations SET status = 'active' WHERE id = '$ORG_IRON'" >/dev/null

# --- clean round-trip: unfreeze Asha same-day (0 elapsed) so her real seed
#     membership is back to active with an UNCHANGED current_period_end ---
got=$(rest_rpc "$PRIYA" "unfreeze_membership" "{\"p_membership_id\":\"$ASHA_MEMBERSHIP\"}")
assert_contains "front_desk unfreezes Asha (own location) -> ok" '"status":"active"' "$got"
assert_contains "  ...days_frozen=0 (same-day round trip)" '"days_frozen":0' "$got"
assert_equals   "  ...current_period_end unchanged (0-day shift)" "$ASHA_BEFORE" \
  "$(sql "select current_period_end from memberships where id='$ASHA_MEMBERSHIP';")"

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
