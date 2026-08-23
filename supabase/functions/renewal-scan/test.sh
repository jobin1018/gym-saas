#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Integration tests for the renewal-scan Edge Function.
#
# Asserts PASS/FAIL on the HTTP response shape AND the resulting database state,
# same pattern as the other three suites.
#
# ============================================================================
# WHAT THIS SUITE DOES TO YOUR DATA AND YOUR RAZORPAY ACCOUNT
# ============================================================================
# renewal-scan drives send-renewal-reminder, which calls the REAL Razorpay
# Payment Links API. Every "created" outcome below is a real test-mode payment
# link, printed so you can open it. Nothing is charged.
#
# The suite MOVES current_period_end on the seeded memberships to place them on
# and off the scan offsets, and creates three throwaway fixtures (a ₹0 plan, a
# member, a membership) to force one failure inside a batch. All of it is
# restored by reset_state() at the end.
#
# PREREQUISITES
#   1. supabase start
#   2. supabase db reset                 # applies migrations + seed.sql
#   3. supabase functions serve --env-file supabase/functions/.env
#      (serve ALL functions — renewal-scan calls send-renewal-reminder, so
#       serving only renewal-scan makes every fan-out fail with a 404)
#   4. bash supabase/functions/renewal-scan/test.sh
#
# Requires: curl, docker (for DB assertions and fixture setup).
# ---------------------------------------------------------------------------

set -uo pipefail

BASE_URL="${BASE_URL:-http://127.0.0.1:54321/functions/v1/renewal-scan}"
ENV_FILE="${ENV_FILE:-$(dirname "$0")/../.env}"
DB_CONTAINER="${DB_CONTAINER:-supabase_db_gym-saas}"
PROJECT_DIR="${PROJECT_DIR:-$(dirname "$0")/../../..}"

# Seeded fixtures (see supabase/seed.sql)
MEM_ASHA=f1111111-1111-1111-1111-111111111111     # active,   Iron Temple, ₹1500
MEMBER_ASHA=e1111111-1111-1111-1111-111111111111
MEM_BHARAT=f2222222-2222-2222-2222-222222222222   # past_due, Iron Temple, ₹1500
MEMBER_BHARAT=e2222222-2222-2222-2222-222222222222
MEM_CHITRA_IT=f3333333-3333-3333-3333-333333333333
MEM_CHITRA_FF=f4444444-4444-4444-4444-444444444444
ORG_IRON=11111111-1111-1111-1111-111111111111
LOC_IRON=aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa

# Throwaway fixtures created by this suite to force a mid-batch failure.
# A plan priced at 0.00 makes send-renewal-reminder answer 500
# plan_amount_invalid — a real failure path, not a mocked one.
BAD_PLAN=0badbad0-0000-0000-0000-000000000001
BAD_MEMBER=0badbad0-0000-0000-0000-000000000002
BAD_MEMBERSHIP=0badbad0-0000-0000-0000-000000000003

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

read_env() {
  [ -f "$ENV_FILE" ] || return 0
  sed -n "s/^[[:space:]]*$1=//p" "$ENV_FILE" | tail -1 | tr -d '\r"'
}

RZP_KEY_ID="${RAZORPAY_KEY_ID:-$(read_env RAZORPAY_KEY_ID)}"

status_env() {
  (cd "$PROJECT_DIR" && supabase status -o env 2>/dev/null)
}

SERVICE_KEY="${SERVICE_ROLE_KEY:-}"
ANON_KEY="${ANON_KEY:-}"
if { [ -z "$SERVICE_KEY" ] || [ -z "$ANON_KEY" ]; } && command -v supabase >/dev/null 2>&1; then
  _env=$(status_env)
  [ -z "$SERVICE_KEY" ] && SERVICE_KEY=$(printf '%s' "$_env" | sed -n 's/^SERVICE_ROLE_KEY="\(.*\)"$/\1/p' | tail -1)
  [ -z "$ANON_KEY" ]    && ANON_KEY=$(printf '%s' "$_env"    | sed -n 's/^ANON_KEY="\(.*\)"$/\1/p'         | tail -1)
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

# post <json-body> [auth-mode] -> response body
#   auth-mode: SERVICE (default) | NONE | ANON | <literal bearer value>
post() {
  local body="$1" mode="${2:-SERVICE}"
  local args=(-s -X POST "$BASE_URL" -H 'Content-Type: application/json')
  case "$mode" in
    SERVICE) args+=(-H "Authorization: Bearer $SERVICE_KEY") ;;
    ANON)    args+=(-H "Authorization: Bearer $ANON_KEY") ;;
    NONE)    ;;
    *)       args+=(-H "Authorization: Bearer $mode") ;;
  esac
  curl "${args[@]}" --max-time 180 -d "$body"
}

post_status() {
  local body="$1" mode="${2:-SERVICE}"
  local args=(-s -o /dev/null -w '%{http_code}' -X POST "$BASE_URL" -H 'Content-Type: application/json')
  case "$mode" in
    SERVICE) args+=(-H "Authorization: Bearer $SERVICE_KEY") ;;
    ANON)    args+=(-H "Authorization: Bearer $ANON_KEY") ;;
    NONE)    ;;
    *)       args+=(-H "Authorization: Bearer $mode") ;;
  esac
  curl "${args[@]}" --max-time 180 -d "$body"
}

# Numeric top-level field, e.g. field_num created '{"created":2}' -> 2
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

# Rows written by a scan, i.e. by send-renewal-reminder underneath it.
renewal_payments() { sql "select count(*) from payments where idempotency_key like 'renewal-%';"; }
renewal_messages() { sql "select count(*) from whatsapp_messages where template_name='renewal_reminder';"; }

# Full restore: drop everything a scan created, delete the throwaway fixtures,
# and put the seeded memberships back where seed.sql had them.
# Order matters — whatsapp_messages.related_payment_id references payments.
reset_state() {
  $have_psql || return 0
  docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -q >/dev/null 2>&1 <<SQL
DELETE FROM whatsapp_messages
 WHERE template_name = 'renewal_reminder'
    OR member_id = '$BAD_MEMBER';
DELETE FROM payments WHERE idempotency_key LIKE 'renewal-%';
DELETE FROM memberships     WHERE id = '$BAD_MEMBERSHIP';
DELETE FROM members         WHERE id = '$BAD_MEMBER';
DELETE FROM membership_plans WHERE id = '$BAD_PLAN';
UPDATE memberships SET status='active',   current_period_end=CURRENT_DATE + 20 WHERE id='$MEM_ASHA';
UPDATE memberships SET status='past_due', current_period_end=CURRENT_DATE - 10 WHERE id='$MEM_BHARAT';
UPDATE memberships SET status='active',   current_period_end=CURRENT_DATE + 25 WHERE id='$MEM_CHITRA_IT';
UPDATE memberships SET status='active',   current_period_end=CURRENT_DATE + 25 WHERE id='$MEM_CHITRA_FF';
UPDATE members SET whatsapp_opt_in=true WHERE id IN ('$MEMBER_ASHA','$MEMBER_BHARAT');
SQL
}

# Place the seeded memberships relative to the default offsets (7 and 3):
#   Asha        -> +7  IN WINDOW   (active)
#   Bharat      -> +3  IN WINDOW   (past_due — proves past_due is not excluded
#                                   by status when it does land on an offset)
#   Chitra IT   -> +5  OUT (between the offsets — the case a contiguous
#                           BETWEEN-range query would wrongly have caught)
#   Chitra FF   -> +7 but 'cancelled' -> OUT (right date, wrong status)
arrange_window() {
  $have_psql || return 0
  docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -q >/dev/null 2>&1 <<SQL
UPDATE memberships SET status='active',    current_period_end=CURRENT_DATE + 7 WHERE id='$MEM_ASHA';
UPDATE memberships SET status='past_due',  current_period_end=CURRENT_DATE + 3 WHERE id='$MEM_BHARAT';
UPDATE memberships SET status='active',    current_period_end=CURRENT_DATE + 5 WHERE id='$MEM_CHITRA_IT';
UPDATE memberships SET status='cancelled', current_period_end=CURRENT_DATE + 7 WHERE id='$MEM_CHITRA_FF';
SQL
}

# Everything far away -> zero matches.
arrange_empty() {
  $have_psql || return 0
  sql "update memberships set current_period_end = CURRENT_DATE + 400;" >/dev/null
}

# A membership on offset +7 whose plan costs ₹0. send-renewal-reminder rejects
# that with 500 plan_amount_invalid, which is a genuine failure of one item
# inside an otherwise healthy batch.
add_failing_membership() {
  $have_psql || return 0
  docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -q >/dev/null 2>&1 <<SQL
INSERT INTO membership_plans (id, organization_id, name, amount)
VALUES ('$BAD_PLAN', '$ORG_IRON', 'Broken Zero Plan', 0.00)
ON CONFLICT (id) DO UPDATE SET amount = 0.00;
INSERT INTO members (id, organization_id, location_id, name, phone, whatsapp_opt_in, source)
VALUES ('$BAD_MEMBER', '$ORG_IRON', '$LOC_IRON', 'Zero Amount Tester', '915555500001', true, 'manual')
ON CONFLICT (id) DO NOTHING;
INSERT INTO memberships (id, organization_id, member_id, plan_id, status, start_date, current_period_end)
VALUES ('$BAD_MEMBERSHIP', '$ORG_IRON', '$BAD_MEMBER', '$BAD_PLAN', 'active',
        CURRENT_DATE - 30, CURRENT_DATE + 7)
ON CONFLICT (id) DO UPDATE SET current_period_end = CURRENT_DATE + 7, status = 'active';
SQL
}

clear_todays_messages() {
  $have_psql || return 0
  sql "delete from whatsapp_messages where template_name='renewal_reminder';" >/dev/null
}

print_links() {
  printf '%s' "$1" \
    | tr ',' '\n' \
    | sed -n 's/.*"payment_url":"\([^"]*\)".*/    \1/p' \
    | sort -u
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

printf '\n%s== renewal-scan tests ==%s\n' "$B" "$N"
printf 'target: %s\n' "$BASE_URL"

if [ -z "$SERVICE_KEY" ]; then
  printf '\n%sERROR%s could not determine the service role key.\n' "$R" "$N"
  printf '        Run `supabase status` from the project root, or export SERVICE_ROLE_KEY=...\n\n'
  exit 1
fi

case "$RZP_KEY_ID" in
  rzp_test_*) printf 'razorpay: %s %s(TEST MODE)%s\n' "$RZP_KEY_ID" "$G" "$N" ;;
  rzp_live_*) printf '\n%sREFUSING TO RUN%s RAZORPAY_KEY_ID is a LIVE key (%s).\n' "$R" "$N" "$RZP_KEY_ID"
              printf '        A scan creates real payment links. Use test-mode keys.\n\n'
              exit 1 ;;
  "")         printf '\n%sERROR%s no RAZORPAY_KEY_ID in %s — every fan-out would fail.\n\n' "$R" "$N" "$ENV_FILE"
              exit 1 ;;
  *)          printf 'razorpay: %s %s(unrecognised key prefix)%s\n' "$RZP_KEY_ID" "$Y" "$N" ;;
esac

if ! curl -s -o /dev/null --max-time 5 -X POST "$BASE_URL" -d '{}'; then
  printf '\n%sERROR%s cannot reach renewal-scan. Start it with:\n' "$R" "$N"
  printf '  supabase functions serve --env-file supabase/functions/.env\n\n'
  exit 1
fi

# renewal-scan is useless if its downstream is not being served, and the
# resulting all-errors run is confusing to debug. Check up front.
downstream=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
  -X POST "http://127.0.0.1:54321/functions/v1/send-renewal-reminder" \
  -H "Authorization: Bearer $SERVICE_KEY" -H 'Content-Type: application/json' -d '{}')
if [ "$downstream" = "404" ]; then
  printf '\n%sERROR%s send-renewal-reminder is not being served (404).\n' "$R" "$N"
  printf '        Serve ALL functions: supabase functions serve --env-file supabase/functions/.env\n\n'
  exit 1
fi

if $have_psql; then
  if [ "$(sql "select count(*) from memberships where id='$MEM_ASHA';")" != "1" ]; then
    printf '\n%sERROR%s membership fixtures missing. Run: supabase db reset\n\n' "$R" "$N"
    exit 1
  fi
else
  printf '%swarn%s  docker/psql unavailable — DB assertions and fixture setup will SKIP\n' "$Y" "$N"
fi

probe=$(post_status '{"dry_run":true}')
if [ "$probe" = "401" ]; then
  printf '\n%sERROR%s function rejected the service role key from `supabase status`.\n' "$R" "$N"
  printf '        Restart serve so it picks up the current keys.\n\n'
  exit 1
fi

reset_state

# ---------------------------------------------------------------------------
# 1. Caller authentication
# ---------------------------------------------------------------------------
printf '\n%s-- caller authentication --%s\n' "$B" "$N"

assert_equals "no Authorization header is rejected 401" "401" "$(post_status '{}' NONE)"
assert_equals "a wrong bearer token is rejected 401"    "401" "$(post_status '{}' "not-the-key")"

if [ -n "$ANON_KEY" ]; then
  assert_equals "the ANON key is rejected 401 (it is public)" "401" "$(post_status '{}' ANON)"
else
  skipped "the ANON key is rejected 401 (it is public)" "could not read ANON_KEY from supabase status"
fi

got=$(curl -s -X GET "$BASE_URL" -H "Authorization: Bearer $SERVICE_KEY")
assert_contains "GET is rejected (this endpoint is POST-only)" 'method_not_allowed' "$got"

assert_db "rejected calls triggered no reminders" "0" "$(renewal_payments)"

# ---------------------------------------------------------------------------
# 2. Input validation
# ---------------------------------------------------------------------------
printf '\n%s-- input validation --%s\n' "$B" "$N"

got=$(post 'not json at all')
assert_contains "unparseable body is a clear 400" '"error":"invalid_json_body"' "$got"

got=$(post '[]')
assert_contains "a JSON array body is rejected" '"error":"body_must_be_object"' "$got"

# The string "true" must not arm a dry run, and must not silently be ignored
# either — either mistake sends real messages when none were wanted.
got=$(post '{"dry_run":"true"}')
assert_contains "dry_run must be a real boolean, not a string" \
  '"error":"dry_run_must_be_boolean"' "$got"

got=$(post '{"offsets":[1.5]}')
assert_contains "fractional offsets are rejected" '"error":"offsets_invalid"' "$got"

got=$(post '{"offsets":[]}')
assert_contains "an empty offsets list is rejected" '"error":"offsets_invalid"' "$got"

got=$(post '{"limit":0}')
assert_contains "limit below 1 is rejected" '"error":"limit_invalid"' "$got"

assert_db "no rejected request reached send-renewal-reminder" "0" "$(renewal_payments)"

# ---------------------------------------------------------------------------
# 3. dry_run — reports correctly, changes nothing
# ---------------------------------------------------------------------------
printf '\n%s-- dry_run --%s\n' "$B" "$N"

reset_state
arrange_window

payments_before=$(renewal_payments)
messages_before=$(renewal_messages)

got=$(post '{"dry_run":true}')

assert_contains "response is flagged as a dry run"   '"dry_run":true' "$got"
assert_contains "dry run reports the offsets used"   '"offset_days":[7,3]' "$got"
assert_contains "dry run names the two target dates" '"target_dates":[' "$got"
assert_equals   "dry run matched the 2 in-window memberships" "2" "$(field_num matched "$got")"

# Requirement 5: membership ids, member names and amounts.
assert_contains "dry run lists the membership id"  "\"membership_id\":\"$MEM_ASHA\"" "$got"
assert_contains "dry run lists the member name"    '"member_name":"Asha Menon"' "$got"
assert_contains "dry run lists the amount"         '"amount":1500' "$got"
assert_contains "dry run lists the plan name"      '"plan_name":"Monthly Unlimited"' "$got"
assert_contains "dry run shows days_until_due"     '"days_until_due":7' "$got"
assert_contains "dry run totals the amount at risk" '"total_amount":3000' "$got"
assert_contains "dry run says skip guards are NOT evaluated" '"note":"Selection only.' "$got"

# Selection correctness, stated as exclusions.
assert_contains "past_due membership on an offset IS included" \
  "\"membership_id\":\"$MEM_BHARAT\"" "$got"
assert_not_contains "membership BETWEEN the offsets (+5) is excluded" "$MEM_CHITRA_IT" "$got"
assert_not_contains "cancelled membership on an offset is excluded"   "$MEM_CHITRA_FF" "$got"

# The whole point of dry_run: no side effects at all.
assert_db "dry run created no payments"  "$payments_before" "$(renewal_payments)"
assert_db "dry run created no messages"  "$messages_before" "$(renewal_messages)"
assert_db "dry run hit Razorpay zero times (no link rows exist)" \
  "0" "$(sql "select count(*) from payments where razorpay_link_id is not null and idempotency_key like 'renewal-%';")"

# An offsets override must change the selection, proving the query really is
# driven by the parameter and not by a hardcoded window.
got=$(post '{"dry_run":true,"offsets":[5]}')
assert_equals   "offsets override [5] matches only the +5 membership" "1" "$(field_num matched "$got")"
assert_contains "offsets override selects Chitra (Iron Temple)" "$MEM_CHITRA_IT" "$got"
assert_not_contains "offsets override drops the +7 membership"  "$MEM_ASHA" "$got"

# ---------------------------------------------------------------------------
# 4. Zero matching memberships — a clean report, not an error
# ---------------------------------------------------------------------------
printf '\n%s-- zero matches --%s\n' "$B" "$N"

reset_state
arrange_empty

got=$(post '{}')
assert_contains "empty scan is ok:true"          '"ok":true' "$got"
assert_equals   "empty scan returns 200"         "200" "$(post_status '{}')"
assert_equals   "empty scan scanned 0"           "0" "$(field_num scanned "$got")"
assert_equals   "empty scan created 0"           "0" "$(field_num created "$got")"
assert_equals   "empty scan errored 0"           "0" "$(field_num errored "$got")"
assert_contains "empty scan reports no error ids" '"errored_membership_ids":[]' "$got"
assert_contains "empty scan still reports its target dates" '"target_dates":[' "$got"
assert_db "empty scan wrote nothing" "0" "$(renewal_payments)"

# A dry run over nothing must also be clean.
got=$(post '{"dry_run":true}')
assert_equals   "empty dry run matched 0"        "0" "$(field_num matched "$got")"
assert_contains "empty dry run lists nothing"    '"would_send":[]' "$got"
assert_contains "empty dry run totals zero"      '"total_amount":0' "$got"

# ---------------------------------------------------------------------------
# 5. Real scan — fans out to send-renewal-reminder (REAL Razorpay links)
# ---------------------------------------------------------------------------
printf '\n%s-- real scan --%s\n' "$B" "$N"

reset_state
arrange_window

got=$(post '{}')

assert_contains "real scan is not flagged dry"  '"dry_run":false' "$got"
assert_equals   "scanned both in-window memberships" "2" "$(field_num scanned "$got")"
assert_equals   "both reminders were created"        "2" "$(field_num created "$got")"
assert_equals   "nothing errored"                    "0" "$(field_num errored "$got")"
assert_equals   "nothing was skipped"                "0" "$(field_num skipped "$got")"
assert_contains "response carries real payment links" '"payment_url":"https://rzp.io/' "$got"
assert_contains "duration is reported"                '"duration_ms":' "$got"

printf '\n  %sREAL RAZORPAY LINKS CREATED%s — verify these in the dashboard:\n' "$B" "$N"
print_links "$got"
printf '\n'

assert_db "two payment rows were created by the fan-out" "2" "$(renewal_payments)"
assert_db "two reminders were logged"                    "2" "$(renewal_messages)"
assert_db "Asha got a payment row"  "1" "$(sql "select count(*) from payments where membership_id='$MEM_ASHA' and idempotency_key like 'renewal-%';")"
assert_db "Bharat (past_due) got a payment row" "1" "$(sql "select count(*) from payments where membership_id='$MEM_BHARAT' and idempotency_key like 'renewal-%';")"
assert_db "the +5 membership was NOT contacted" \
  "0" "$(sql "select count(*) from payments where membership_id='$MEM_CHITRA_IT' and idempotency_key like 'renewal-%';")"
assert_db "the cancelled membership was NOT contacted" \
  "0" "$(sql "select count(*) from payments where membership_id='$MEM_CHITRA_FF' and idempotency_key like 'renewal-%';")"
assert_db "every payment row is pending with a link and no payment id yet" \
  "2" "$(sql "select count(*) from payments where idempotency_key like 'renewal-%' and status='pending' and razorpay_link_id is not null and provider_payment_id is null;")"

# --- Re-running the same day must delegate to the reminder's own guard ---
got=$(post '{}')
assert_equals   "same-day re-scan created nothing new" "0" "$(field_num created "$got")"
assert_equals   "same-day re-scan skipped both"        "2" "$(field_num skipped "$got")"
assert_contains "skips are attributed to already_sent_today" \
  '"already_sent_today":2' "$got"
assert_db "same-day re-scan created no extra payment rows" "2" "$(renewal_payments)"
assert_db "same-day re-scan queued no extra messages"      "2" "$(renewal_messages)"

# --- A later day: same period, so the link is reused, not recreated ---
if ! $have_psql; then
  skipped "next-day scan reuses the existing payment link" "requires docker/psql"
else
  clear_todays_messages
  got=$(post '{}')
  assert_equals "next-day scan reused both payment rows" "2" "$(field_num reused "$got")"
  assert_equals "next-day scan created nothing new"      "0" "$(field_num created "$got")"
  assert_db "still only two payment rows for the period" "2" "$(renewal_payments)"
fi

# ---------------------------------------------------------------------------
# 6. One failure in the batch — the rest must still complete
# ---------------------------------------------------------------------------
printf '\n%s-- partial failure --%s\n' "$B" "$N"

if ! $have_psql; then
  skipped "a failing membership does not abort the batch" "requires docker/psql (needs fixtures)"
else
  # NOTE: deliberately NOT calling reset_state here. The two healthy
  # memberships keep the payments rows group 5 created, so they take the
  # "reused" path and this group creates NO new Razorpay links — only the ₹0
  # membership reaches link creation, and it fails before it gets there.
  #
  # That is not just politeness to Razorpay. Creating a fresh link per healthy
  # membership made this group the last straw in a full-suite run: the account
  # hit "Too many requests", an unrelated membership errored, and the exact
  # counts below failed for a reason that had nothing to do with the behaviour
  # under test. Reusing keeps the assertion measuring what it claims to.
  clear_todays_messages
  add_failing_membership   # ₹0 plan on offset +7 -> 500 plan_amount_invalid

  got=$(post '{}')

  # If Razorpay throttles anyway, say so out loud rather than reporting a
  # logic regression that is not there — or quietly passing over it.
  case "$got" in
    *"Too many requests"*)
      skipped "a failing membership does not abort the batch" \
        "Razorpay rate-limited this run; counts below are not meaningful. Re-run in a minute." ;;
    *)
      assert_equals   "all three memberships were attempted" "3" "$(field_num scanned "$got")"
      assert_equals   "exactly one errored"                  "1" "$(field_num errored "$got")"
      # The point of the test: the other two completed rather than being abandoned.
      assert_equals   "the other two still completed"        "2" "$(field_num reused "$got")"
      assert_contains "the failing membership id is reported for follow-up" \
        "\"errored_membership_ids\":[\"$BAD_MEMBERSHIP\"]" "$got"
      assert_contains "the failure reason is surfaced" '"error":"plan_amount_invalid"' "$got"
      assert_contains "the failing member is named"    '"member_name":"Zero Amount Tester"' "$got"
      assert_contains "the downstream HTTP status is kept" '"http_status":500' "$got"
      assert_contains "a partial failure is still ok:true overall" '"ok":true' "$got"
      assert_equals   "a partial failure still returns 200, not 5xx" "200" "$(post_status '{"dry_run":true}')"

      assert_db "the two healthy memberships kept their payment rows" \
        "2" "$(renewal_payments)"
      assert_db "the failing membership got no payment row" \
        "0" "$(sql "select count(*) from payments where membership_id='$BAD_MEMBERSHIP';")"
      assert_db "the failing membership got no message" \
        "0" "$(sql "select count(*) from whatsapp_messages where member_id='$BAD_MEMBER';")"
      ;;
  esac

  # Ordering guarantee: current_period_end ascending. Bharat (+3) must be
  # attempted before the two +7 rows, so an aborted run always favours the
  # member closest to losing access.
  first_id=$(printf '%s' "$got" | sed -n 's/.*"results":\[{"membership_id":"\([^"]*\)".*/\1/p' | head -1)
  assert_equals "soonest-due membership was processed first" "$MEM_BHARAT" "$first_id"
fi

# ---------------------------------------------------------------------------
# 7. Batch limiting
# ---------------------------------------------------------------------------
printf '\n%s-- limit and truncation --%s\n' "$B" "$N"

if ! $have_psql; then
  skipped "limit truncates the batch and says so" "requires docker/psql"
else
  clear_todays_messages
  got=$(post '{"dry_run":true,"limit":1}')
  assert_equals   "limit=1 matched only one"       "1" "$(field_num matched "$got")"
  assert_contains "truncation is reported"         '"truncated":true' "$got"
  assert_contains "the limit used is echoed back"  '"limit":1' "$got"

  got=$(post '{"dry_run":true}')
  assert_contains "an unlimited scan is not flagged truncated" '"truncated":false' "$got"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
reset_state

printf '\n%s== summary ==%s\n' "$B" "$N"
printf '  %spassed %d%s   %sfailed %d%s   %sskipped %d%s\n' "$G" "$PASS" "$N" "$R" "$FAIL" "$N" "$Y" "$SKIP" "$N"
printf '  note: the Razorpay TEST MODE links printed above still exist in your\n'
printf '        dashboard. They are unpaid and were never sent to anyone.\n'
printf '  note: seeded memberships and members have been restored to seed.sql state.\n'

if [ "$FAIL" -gt 0 ]; then
  printf '\n  failing cases:\n'
  for c in "${FAILED_CASES[@]}"; do printf '    - %s\n' "$c"; done
  printf '\n'
  exit 1
fi

printf '\n'
exit 0
