#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Integration tests for the mark-overdue Edge Function.
#
# Asserts PASS/FAIL on the HTTP response shape AND the resulting database state,
# same pattern as the other five suites.
#
# ============================================================================
# THE BOUNDARY IS THE POINT
# ============================================================================
# A membership ending TODAY is valid all day and must not be touched. One
# ending YESTERDAY is overdue. Most of this suite exists to pin those two cases
# either side of a strict `<` comparison, because getting it wrong by one day
# marks a paying member delinquent on the morning their renewal reminder goes
# out — while they can still walk in and pay.
#
# The last group closes the loop the other way: it drives a REAL signed
# razorpay-webhook delivery to prove a past_due membership flips back to active
# when it is paid, rather than trusting a code reading.
#
# PREREQUISITES
#   1. supabase start
#   2. supabase db reset                 # applies migrations + seed.sql
#   3. supabase functions serve --env-file supabase/functions/.env
#      (serve ALL functions — the reverse-transition group posts to
#       razorpay-webhook)
#   4. bash supabase/functions/mark-overdue/test.sh
#
# Requires: curl, docker (for DB assertions), openssl (for the webhook signature).
# No external API is called and nothing is charged.
# ---------------------------------------------------------------------------

set -uo pipefail

BASE_URL="${BASE_URL:-http://127.0.0.1:54321/functions/v1/mark-overdue}"
WEBHOOK_URL="${WEBHOOK_URL:-http://127.0.0.1:54321/functions/v1/razorpay-webhook}"
ENV_FILE="${ENV_FILE:-$(dirname "$0")/../.env}"
DB_CONTAINER="${DB_CONTAINER:-supabase_db_gym-saas}"
PROJECT_DIR="${PROJECT_DIR:-$(dirname "$0")/../../..}"

# Seeded fixtures (see supabase/seed.sql)
MEM_ASHA=f1111111-1111-1111-1111-111111111111
MEM_BHARAT=f2222222-2222-2222-2222-222222222222
MEM_CHITRA_IT=f3333333-3333-3333-3333-333333333333
MEM_CHITRA_FF=f4444444-4444-4444-4444-444444444444
PAY_CAPTURED=a1111111-1111-1111-1111-111111111111   # provider_payment_id pay_TEST_CAPTURED
ORG_IRON=11111111-1111-1111-1111-111111111111

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

WEBHOOK_SECRET="${RAZORPAY_WEBHOOK_SECRET:-$(read_env RAZORPAY_WEBHOOK_SECRET)}"

SERVICE_KEY="${SERVICE_ROLE_KEY:-}"
ANON_KEY="${ANON_KEY:-}"
if { [ -z "$SERVICE_KEY" ] || [ -z "$ANON_KEY" ]; } && command -v supabase >/dev/null 2>&1; then
  _env=$( (cd "$PROJECT_DIR" && supabase status -o env 2>/dev/null) )
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

post() {
  local body="$1" mode="${2:-SERVICE}"
  local args=(-s -X POST "$BASE_URL" -H 'Content-Type: application/json')
  case "$mode" in
    SERVICE) args+=(-H "Authorization: Bearer $SERVICE_KEY") ;;
    ANON)    args+=(-H "Authorization: Bearer $ANON_KEY") ;;
    NONE)    ;;
    *)       args+=(-H "Authorization: Bearer $mode") ;;
  esac
  curl "${args[@]}" --max-time 120 -d "$body"
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
  curl "${args[@]}" --max-time 120 -d "$body"
}

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

status_of() { sql "select status from memberships where id='$1';"; }

reset_state() {
  $have_psql || return 0
  docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -q >/dev/null 2>&1 <<SQL
DELETE FROM whatsapp_messages WHERE template_name IN ('daily_owner_brief','renewal_reminder')
                                 OR related_payment_id IS NOT NULL;
DELETE FROM payments WHERE idempotency_key LIKE 'renewal-%';
DELETE FROM webhook_events WHERE source = 'razorpay';
UPDATE payments SET status='pending', reconciled_at=NULL,
       provider_payment_id='pay_TEST_CAPTURED', razorpay_link_id=NULL
 WHERE id='$PAY_CAPTURED';
UPDATE memberships SET status='active',   current_period_end=CURRENT_DATE + 20 WHERE id='$MEM_ASHA';
UPDATE memberships SET status='past_due', current_period_end=CURRENT_DATE - 10 WHERE id='$MEM_BHARAT';
UPDATE memberships SET status='active',   current_period_end=CURRENT_DATE + 25 WHERE id='$MEM_CHITRA_IT';
UPDATE memberships SET status='active',   current_period_end=CURRENT_DATE + 25 WHERE id='$MEM_CHITRA_FF';
SQL
}

# The boundary fixture. All four memberships are 'active'; only their dates
# differ, so nothing but the date comparison can explain the outcome.
#
#   Asha       current_period_end = YESTERDAY  -> MUST transition
#   Bharat     current_period_end = 30 days ago -> MUST transition
#   Chitra IT  current_period_end = TODAY      -> MUST NOT (valid all day)
#   Chitra FF  current_period_end = TOMORROW   -> MUST NOT
arrange_boundary() {
  $have_psql || return 0
  docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -q >/dev/null 2>&1 <<SQL
UPDATE memberships SET status='active', current_period_end=CURRENT_DATE - 1  WHERE id='$MEM_ASHA';
UPDATE memberships SET status='active', current_period_end=CURRENT_DATE - 30 WHERE id='$MEM_BHARAT';
UPDATE memberships SET status='active', current_period_end=CURRENT_DATE      WHERE id='$MEM_CHITRA_IT';
UPDATE memberships SET status='active', current_period_end=CURRENT_DATE + 1  WHERE id='$MEM_CHITRA_FF';
SQL
}

# ---------------------------------------------------------------------------
# Mock-Razorpay transport (for the reverse-transition group only)
# ---------------------------------------------------------------------------

sign() { printf '%s' "$1" | openssl dgst -sha256 -hmac "$WEBHOOK_SECRET" | sed 's/^.*= *//'; }

payment_event() {
  printf '{"entity":"event","account_id":"acc_TEST","event":"%s","id":"%s","contains":["payment"],"payload":{"payment":{"entity":{"id":"%s","entity":"payment","amount":%s,"currency":"INR","status":"captured","method":"upi","captured":true}}},"created_at":1767225600}' \
    "$1" "$2" "$3" "$4"
}

post_webhook() {
  curl -s -X POST "$WEBHOOK_URL" -H 'Content-Type: application/json' \
    -H "X-Razorpay-Signature: $(sign "$1")" --max-time 60 -d "$1"
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

printf '\n%s== mark-overdue tests ==%s\n' "$B" "$N"
printf 'target: %s\n' "$BASE_URL"

if [ -z "$SERVICE_KEY" ]; then
  printf '\n%sERROR%s could not determine the service role key.\n' "$R" "$N"
  printf '        Run `supabase status` from the project root, or export SERVICE_ROLE_KEY=...\n\n'
  exit 1
fi

if ! curl -s -o /dev/null --max-time 5 -X POST "$BASE_URL" -d '{}'; then
  printf '\n%sERROR%s cannot reach the function. Start it with:\n' "$R" "$N"
  printf '  supabase functions serve --env-file supabase/functions/.env\n\n'
  exit 1
fi

if $have_psql; then
  if [ "$(sql "select count(*) from memberships where id='$MEM_ASHA';")" != "1" ]; then
    printf '\n%sERROR%s membership fixtures missing. Run: supabase db reset\n\n' "$R" "$N"
    exit 1
  fi
  # The function reads the tenant timezone from locations; if the seed ever
  # changes that, the boundary assertions below silently shift by a day.
  tz=$(sql "select timezone from locations where organization_id='$ORG_IRON' order by created_at limit 1;")
  printf 'tenant timezone: %s\n' "${tz:-<none>}"
  if [ "$tz" != "Asia/Kolkata" ]; then
    printf '%swarn%s  boundary fixtures assume Asia/Kolkata; got "%s"\n' "$Y" "$N" "$tz"
  fi
else
  printf '%swarn%s  docker/psql unavailable — DB assertions will SKIP\n' "$Y" "$N"
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

# This function writes membership status — an unauthorized caller must not have
# been able to change anything. Scoped to this suite's 4 known fixtures, not a
# global count — seed.sql now realistically seeds past_due/expired/cancelled
# memberships elsewhere, which this assertion was never testing against.
assert_db "rejected calls changed no membership status" \
  "0" "$(sql "select count(*) from memberships where status='past_due' and id<>'$MEM_BHARAT' and id in ('$MEM_ASHA','$MEM_BHARAT','$MEM_CHITRA_IT','$MEM_CHITRA_FF');")"

# ---------------------------------------------------------------------------
# 2. Input validation
# ---------------------------------------------------------------------------
printf '\n%s-- input validation --%s\n' "$B" "$N"

assert_contains "unparseable body is a clear 400" '"error":"invalid_json_body"' "$(post 'not json')"
assert_contains "a JSON array body is rejected"   '"error":"body_must_be_object"' "$(post '[]')"
assert_contains "dry_run must be a real boolean"  '"error":"dry_run_must_be_boolean"' "$(post '{"dry_run":"true"}')"
assert_contains "limit below 1 is rejected"       '"error":"limit_invalid"' "$(post '{"limit":0}')"

# ---------------------------------------------------------------------------
# 3. dry_run — reports correctly, writes nothing
# ---------------------------------------------------------------------------
printf '\n%s-- dry_run --%s\n' "$B" "$N"

reset_state
arrange_boundary

got=$(post '{"dry_run":true}')

assert_contains "response is flagged as a dry run" '"dry_run":true' "$got"
assert_contains "the transition direction is stated" '"from_status":"active"' "$got"
assert_contains "the target status is stated"        '"to_status":"past_due"' "$got"
assert_contains "the tenant timezone is reported"    '"timezone":"Asia/Kolkata"' "$got"
assert_equals   "dry run found the two lapsed memberships" "2" "$(field_num would_transition "$got")"
assert_contains "dry run names the yesterday membership" "$MEM_ASHA" "$got"
assert_contains "dry run names the long-overdue membership" "$MEM_BHARAT" "$got"
assert_contains "dry run reports days_overdue"        '"days_overdue":1' "$got"
assert_not_contains "dry run never reports a transitioned count" '"transitioned":' "$got"

# Boundary, reported.
assert_not_contains "dry run excludes the membership due TODAY"    "$MEM_CHITRA_IT" "$got"
assert_not_contains "dry run excludes the membership due TOMORROW" "$MEM_CHITRA_FF" "$got"

# The whole point of dry_run.
assert_db "dry run left Asha active"      "active" "$(status_of "$MEM_ASHA")"
assert_db "dry run left Bharat active"    "active" "$(status_of "$MEM_BHARAT")"
assert_db "dry run changed nothing at all" \
  "0" "$(sql "select count(*) from memberships where status='past_due' and id in ('$MEM_ASHA','$MEM_BHARAT','$MEM_CHITRA_IT','$MEM_CHITRA_FF');")"

# ---------------------------------------------------------------------------
# 4. Real run — the boundary
# ---------------------------------------------------------------------------
printf '\n%s-- real run: the today/yesterday boundary --%s\n' "$B" "$N"

got=$(post '{}')

assert_contains "response is not flagged dry"  '"dry_run":false' "$got"
assert_equals   "exactly two memberships transitioned" "2" "$(field_num transitioned "$got")"
assert_equals   "no zone errored"                      "0" "$(field_num errored "$got")"
assert_contains "the transitioned ids are listed"      '"transitioned_membership_ids":[' "$got"
assert_contains "Asha is in the transitioned list"     "$MEM_ASHA" "$got"

# The two that must change.
assert_db "membership due YESTERDAY became past_due"    "past_due" "$(status_of "$MEM_ASHA")"
assert_db "membership 30 days overdue became past_due"  "past_due" "$(status_of "$MEM_BHARAT")"

# The two that must not — this is the assertion that fails if `<` ever becomes `<=`.
assert_db "membership due TODAY is still active (valid all day)" \
  "active" "$(status_of "$MEM_CHITRA_IT")"
assert_db "membership due TOMORROW is still active" \
  "active" "$(status_of "$MEM_CHITRA_FF")"

# Nothing but status may have moved.
assert_db "current_period_end was not modified" \
  "2" "$(sql "select count(*) from memberships where id in ('$MEM_ASHA','$MEM_BHARAT') and current_period_end < CURRENT_DATE;")"
# Scoped to this suite's 4 known fixtures — mark-overdue never sets
# expired/cancelled itself (only active->past_due), so this is really asking
# "did this function touch a status it has no business touching" for the rows
# it actually operated on. seed.sql now realistically seeds real
# expired/cancelled memberships elsewhere on purpose.
assert_db "no membership was pushed to expired or cancelled" \
  "0" "$(sql "select count(*) from memberships where status in ('expired','cancelled') and id in ('$MEM_ASHA','$MEM_BHARAT','$MEM_CHITRA_IT','$MEM_CHITRA_FF');")"

# ---------------------------------------------------------------------------
# 5. Re-running is safe
# ---------------------------------------------------------------------------
printf '\n%s-- idempotency --%s\n' "$B" "$N"

got=$(post '{}')
assert_equals   "second run transitions nothing"     "0" "$(field_num transitioned "$got")"
assert_equals   "second run finds nothing eligible"  "0" "$(field_num eligible "$got")"
assert_contains "second run returns an empty id list" '"transitioned_membership_ids":[]' "$got"
assert_contains "second run is still ok:true"        '"ok":true' "$got"
assert_equals   "second run returns 200"             "200" "$(post_status '{}')"

assert_db "already-past_due rows were left alone" "past_due" "$(status_of "$MEM_ASHA")"
assert_db "still exactly two past_due (of this suite's 4 known fixtures)" \
  "2" "$(sql "select count(*) from memberships where status='past_due' and id in ('$MEM_ASHA','$MEM_BHARAT','$MEM_CHITRA_IT','$MEM_CHITRA_FF');")"

got=$(post '{}')
assert_equals "a third run also transitions nothing" "0" "$(field_num transitioned "$got")"

# A dry run after everything has transitioned must also report zero.
got=$(post '{"dry_run":true}')
assert_equals "dry run after the fact reports nothing pending" "0" "$(field_num would_transition "$got")"

# ---------------------------------------------------------------------------
# 6. past_due is never touched in the other direction
# ---------------------------------------------------------------------------
printf '\n%s-- past_due is not re-processed --%s\n' "$B" "$N"

# A membership already past_due whose date is in the future (as happens the
# moment razorpay-webhook extends it but before status settles) must be ignored
# entirely — this function only ever reads status='active'.
if ! $have_psql; then
  skipped "a past_due membership with a future date is untouched" "requires docker/psql"
else
  sql "update memberships set status='past_due', current_period_end=CURRENT_DATE + 30 where id='$MEM_CHITRA_IT';" >/dev/null
  got=$(post '{}')
  assert_equals "run transitions nothing" "0" "$(field_num transitioned "$got")"
  assert_db "the past_due/future-dated membership is untouched" \
    "past_due" "$(status_of "$MEM_CHITRA_IT")"
fi

# ---------------------------------------------------------------------------
# 7. THE REVERSE TRANSITION — proven with a real signed webhook
#
# Requirement 5 asked whether paying a past_due membership already flips it back
# to active via razorpay-webhook. Reading that code says yes: on payment success
# it writes { status: 'active', current_period_end: <extended> } unconditionally,
# without consulting the previous status (razorpay-webhook/index.ts:484-485).
#
# This group proves it rather than asserting it: mark-overdue puts a membership
# into past_due, then a correctly-signed payment.captured is delivered and the
# membership must come back out.
# ---------------------------------------------------------------------------
printf '\n%s-- reverse transition (real razorpay-webhook delivery) --%s\n' "$B" "$N"

if [ -z "$WEBHOOK_SECRET" ]; then
  skipped "paying a past_due membership flips it back to active" \
    "no RAZORPAY_WEBHOOK_SECRET in $ENV_FILE"
elif ! command -v openssl >/dev/null 2>&1; then
  skipped "paying a past_due membership flips it back to active" \
    "openssl is required to sign the webhook"
elif ! $have_psql; then
  skipped "paying a past_due membership flips it back to active" "requires docker/psql"
else
  reset_state
  # Asha lapsed 5 days ago and is still marked active; her seeded payment row
  # (pay_TEST_CAPTURED) is attached to this membership and still pending.
  sql "update memberships set status='active', current_period_end=CURRENT_DATE - 5 where id='$MEM_ASHA';" >/dev/null

  # Step 1: mark-overdue puts her past_due.
  got=$(post '{}')
  assert_equals "mark-overdue transitioned the lapsed membership" "1" "$(field_num transitioned "$got")"
  assert_db "membership is now past_due"  "past_due" "$(status_of "$MEM_ASHA")"

  end_before=$(sql "select current_period_end from memberships where id='$MEM_ASHA';")

  # Step 2: a real, correctly-signed payment.captured for her pending payment.
  RUN=$$-$(date +%s)
  hook=$(post_webhook "$(payment_event "payment.captured" "evt_$RUN.revert" "pay_TEST_CAPTURED" 150000)")

  assert_contains "the webhook reconciled the payment" '"handled":"payment_success"' "$hook"
  assert_contains "it matched by provider_payment_id"  '"matched_by":"provider_payment_id"' "$hook"

  # The actual claim under test.
  assert_db "paying a past_due membership flipped it back to ACTIVE" \
    "active" "$(status_of "$MEM_ASHA")"
  assert_db "the payment was marked success" \
    "success" "$(sql "select status from payments where id='$PAY_CAPTURED';")"
  assert_db "the period was extended past today" \
    "t" "$(sql "select (current_period_end > CURRENT_DATE)::bool from memberships where id='$MEM_ASHA';")"
  assert_db "the period actually moved forward" \
    "t" "$(sql "select (current_period_end > date '$end_before')::bool from memberships where id='$MEM_ASHA';")"

  # Step 3: and mark-overdue must now leave her alone — the loop is closed.
  got=$(post '{}')
  assert_equals "mark-overdue no longer sees the paid membership" "0" "$(field_num transitioned "$got")"
  assert_db "the paid membership stays active" "active" "$(status_of "$MEM_ASHA")"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
reset_state

printf '\n%s== summary ==%s\n' "$B" "$N"
printf '  %spassed %d%s   %sfailed %d%s   %sskipped %d%s\n' "$G" "$PASS" "$N" "$R" "$FAIL" "$N" "$Y" "$SKIP" "$N"
printf '  note: no external API was called; seed data restored to seed.sql state.\n'

if [ "$FAIL" -gt 0 ]; then
  printf '\n  failing cases:\n'
  for c in "${FAILED_CASES[@]}"; do printf '    - %s\n' "$c"; done
  printf '\n'
  exit 1
fi

printf '\n'
exit 0
