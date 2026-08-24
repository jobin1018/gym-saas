#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Integration tests for the send-renewal-reminder Edge Function.
#
# Asserts PASS/FAIL on the HTTP response shape AND the resulting database state,
# same pattern as whatsapp-webhook/test.sh and razorpay-webhook/test.sh.
#
# ============================================================================
# THESE TESTS HIT THE REAL RAZORPAY API
# ============================================================================
# Unlike the two webhook suites — which mock the provider by signing their own
# payloads — this suite cannot mock the provider, because the function CALLS
# Razorpay rather than being called by it. Every "created" case below creates a
# real payment link in your Razorpay TEST MODE account, and prints its short_url
# so you can open it. Nothing is charged: test-mode links only accept test
# instruments. The links this suite leaves behind are unpaid and unsent; delete
# them from the dashboard if you like tidy test data.
#
# The WhatsApp send is REAL by default (see ../_shared/whatsapp.ts) — this
# suite forces WHATSAPP_SEND_MODE=mock (checked in preflight below) so it
# never fires a real Meta API call at the seeded test phone number. The
# whatsapp_messages rows asserted on below are real rows, written by the
# mocked send.
#
# PREREQUISITES
#   1. supabase start
#   2. supabase db reset                 # applies migrations + seed.sql
#   3. supabase functions serve send-renewal-reminder --env-file supabase/functions/.env
#   4. bash supabase/functions/send-renewal-reminder/test.sh
#
# Requires: curl, docker (for DB assertions), and RAZORPAY_KEY_ID /
# RAZORPAY_KEY_SECRET in supabase/functions/.env.
# ---------------------------------------------------------------------------

set -uo pipefail

BASE_URL="${BASE_URL:-http://127.0.0.1:54321/functions/v1/send-renewal-reminder}"
ENV_FILE="${ENV_FILE:-$(dirname "$0")/../.env}"
DB_CONTAINER="${DB_CONTAINER:-supabase_db_gym-saas}"
PROJECT_DIR="${PROJECT_DIR:-$(dirname "$0")/../../..}"

# Seeded fixtures (see supabase/seed.sql)
MEM_PAST_DUE=f2222222-2222-2222-2222-222222222222  # Bharat Rao, opt-in, ends CURRENT_DATE - 10
MEMBER_PAST_DUE=e2222222-2222-2222-2222-222222222222
ORG_IRON=11111111-1111-1111-1111-111111111111

MEM_OTHER_ORG=f4444444-4444-4444-4444-444444444444 # Chitra @ FlexFit, plan ₹2000
MEMBER_OTHER_ORG=e4444444-4444-4444-4444-444444444444

GHOST_MEMBERSHIP=f9999999-9999-9999-9999-999999999999  # well-formed uuid, no row

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
WA_SEND_MODE="${WHATSAPP_SEND_MODE:-$(read_env WHATSAPP_SEND_MODE)}"

# The service role key is injected into the function by the edge runtime, not by
# .env — so ask the CLI for it rather than reading a file. authorize() in
# index.ts prefers SUPABASE_SERVICE_ROLE_KEY, which is what this is.
SERVICE_KEY="${SERVICE_ROLE_KEY:-}"
if [ -z "$SERVICE_KEY" ] && command -v supabase >/dev/null 2>&1; then
  SERVICE_KEY=$( (cd "$PROJECT_DIR" && supabase status -o env 2>/dev/null) \
    | sed -n 's/^SERVICE_ROLE_KEY="\(.*\)"$/\1/p' | tail -1 )
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

# post <membership_id|RAW:body> [auth-mode] -> response body
#   auth-mode: SERVICE (default) | NONE | ANON | <literal bearer value>
post() {
  local payload="$1" mode="${2:-SERVICE}" body
  case "$payload" in
    RAW:*) body="${payload#RAW:}" ;;
    *)     body="{\"membership_id\":\"$payload\"}" ;;
  esac

  local args=(-s -X POST "$BASE_URL" -H 'Content-Type: application/json')
  case "$mode" in
    SERVICE) args+=(-H "Authorization: Bearer $SERVICE_KEY") ;;
    ANON)    args+=(-H "Authorization: Bearer $ANON_KEY") ;;
    NONE)    ;;
    *)       args+=(-H "Authorization: Bearer $mode") ;;
  esac

  curl "${args[@]}" -d "$body"
}

# post_status <...> -> HTTP status code only
post_status() {
  local payload="$1" mode="${2:-SERVICE}" body
  case "$payload" in
    RAW:*) body="${payload#RAW:}" ;;
    *)     body="{\"membership_id\":\"$payload\"}" ;;
  esac

  local args=(-s -o /dev/null -w '%{http_code}' -X POST "$BASE_URL" -H 'Content-Type: application/json')
  case "$mode" in
    SERVICE) args+=(-H "Authorization: Bearer $SERVICE_KEY") ;;
    ANON)    args+=(-H "Authorization: Bearer $ANON_KEY") ;;
    NONE)    ;;
    *)       args+=(-H "Authorization: Bearer $mode") ;;
  esac

  curl "${args[@]}" -d "$body"
}

# Pull a top-level string field out of a JSON response without needing jq.
field() { printf '%s' "$2" | sed -n "s/.*\"$1\":\"\([^\"]*\)\".*/\1/p" | head -1; }

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

# Restore fixtures. whatsapp_messages must be cleared BEFORE payments:
# related_payment_id references payments.
#
# Only rows this suite created are removed — payments with a 'renewal-%'
# idempotency_key. The three seeded 'seed-idem-%' fixtures are left alone so the
# razorpay-webhook suite still has its inputs.
reset_state() {
  $have_psql || return 0
  docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -q >/dev/null 2>&1 <<SQL
DELETE FROM whatsapp_messages
 WHERE related_payment_id IN (SELECT id FROM payments WHERE idempotency_key LIKE 'renewal-%')
    OR template_name = 'renewal_reminder';
DELETE FROM payments WHERE idempotency_key LIKE 'renewal-%';
UPDATE memberships SET status='past_due', current_period_end=CURRENT_DATE - 10 WHERE id='$MEM_PAST_DUE';
UPDATE memberships SET status='active',   current_period_end=CURRENT_DATE + 25 WHERE id='$MEM_OTHER_ORG';
UPDATE members SET whatsapp_opt_in=true WHERE id IN ('$MEMBER_PAST_DUE','$MEMBER_OTHER_ORG');
SQL
}

# Drop today's reminder rows for one member, leaving the payments row intact.
# This is how the suite simulates "tomorrow": guard #1 (once per day) is cleared
# while guard #2 (one payment per renewal period) is not.
clear_todays_message() {
  $have_psql || return 0
  sql "DELETE FROM whatsapp_messages WHERE member_id='$1' AND template_name='renewal_reminder';" >/dev/null
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

printf '\n%s== send-renewal-reminder tests ==%s\n' "$B" "$N"
printf 'target: %s\n' "$BASE_URL"

if [ -z "$SERVICE_KEY" ]; then
  printf '\n%sERROR%s could not determine the service role key.\n' "$R" "$N"
  printf '        Run `supabase status` from the project root, or export SERVICE_ROLE_KEY=...\n'
  printf '        The function rejects every other caller with 401, by design.\n\n'
  exit 1
fi

if [ "$(printf '%s' "$WA_SEND_MODE" | tr '[:upper:]' '[:lower:]')" != "mock" ]; then
  printf '\n%sREFUSING TO RUN%s WHATSAPP_SEND_MODE is not "mock" in %s (got: %s).\n' \
    "$R" "$N" "$ENV_FILE" "${WA_SEND_MODE:-<unset>}"
  printf '        This suite sends a real renewal reminder, which calls sendWhatsAppMessage(),\n'
  printf '        which hits the real Meta Cloud API LIVE by default. Set WHATSAPP_SEND_MODE=mock\n'
  printf '        in %s and restart `supabase functions serve` before running this\n' "$ENV_FILE"
  printf '        suite, or it will send a real WhatsApp message to the seeded test phone number.\n\n'
  exit 1
fi

if [ -z "$RZP_KEY_ID" ]; then
  printf '\n%sERROR%s no RAZORPAY_KEY_ID found in %s\n' "$R" "$N" "$ENV_FILE"
  printf '        The function returns 500 razorpay_not_configured without it.\n\n'
  exit 1
fi
case "$RZP_KEY_ID" in
  rzp_test_*) printf 'razorpay: %s %s(TEST MODE)%s\n' "$RZP_KEY_ID" "$G" "$N" ;;
  rzp_live_*) printf '\n%sREFUSING TO RUN%s RAZORPAY_KEY_ID is a LIVE key (%s).\n' "$R" "$N" "$RZP_KEY_ID"
              printf '        This suite creates real payment links. Use test-mode keys.\n\n'
              exit 1 ;;
  *)          printf 'razorpay: %s %s(unrecognised key prefix)%s\n' "$RZP_KEY_ID" "$Y" "$N" ;;
esac

if ! curl -s -o /dev/null --max-time 5 -X POST "$BASE_URL" -d '{}'; then
  printf '\n%sERROR%s cannot reach the function. Start it with:\n' "$R" "$N"
  printf '  supabase functions serve send-renewal-reminder --env-file supabase/functions/.env\n\n'
  exit 1
fi

if $have_psql; then
  if [ "$(sql "select count(*) from memberships where id='$MEM_PAST_DUE';")" != "1" ]; then
    printf '\n%sERROR%s membership fixtures missing. Run: supabase db reset\n\n' "$R" "$N"
    exit 1
  fi
else
  printf '%swarn%s  docker/psql unavailable — database assertions will SKIP\n' "$Y" "$N"
fi

# Confirm the key we send is the one authorize() expects, before attributing any
# later 401 to business logic.
probe=$(post_status "$GHOST_MEMBERSHIP")
if [ "$probe" = "401" ]; then
  printf '\n%sERROR%s function rejected the service role key from `supabase status`.\n' "$R" "$N"
  printf '        Restart serve so it picks up the current keys.\n\n'
  exit 1
fi

reset_state

# ---------------------------------------------------------------------------
# 1. Caller authentication
#
# verify_jwt = true alone is NOT enough: it accepts the anon key, which is
# public in any client app. The anon case below is the one that matters.
# ---------------------------------------------------------------------------
printf '\n%s-- caller authentication --%s\n' "$B" "$N"

assert_equals "no Authorization header is rejected 401" "401" "$(post_status "$MEM_PAST_DUE" NONE)"
assert_equals "a wrong bearer token is rejected 401"    "401" "$(post_status "$MEM_PAST_DUE" "not-the-key")"

if [ -n "$ANON_KEY" ]; then
  got=$(post_status "$MEM_PAST_DUE" ANON)
  assert_equals "the ANON key is rejected 401 (it is public)" "401" "$got"
else
  skipped "the ANON key is rejected 401 (it is public)" "could not read ANON_KEY from supabase status"
fi

got=$(curl -s -X GET "$BASE_URL" -H "Authorization: Bearer $SERVICE_KEY")
assert_contains "GET is rejected (this endpoint is POST-only)" 'method_not_allowed' "$got"

# Requirement: a rejected call must not have created anything.
assert_db "rejected calls created no payment rows" \
  "0" "$(sql "select count(*) from payments where idempotency_key like 'renewal-%';")"

# ---------------------------------------------------------------------------
# 2. Input validation
# ---------------------------------------------------------------------------
printf '\n%s-- input validation --%s\n' "$B" "$N"

got=$(post "RAW:{}")
assert_contains "missing membership_id is a clear 400" '"error":"membership_id_required"' "$got"
assert_equals   "missing membership_id returns 400"    "400" "$(post_status "RAW:{}")"

got=$(post "RAW:not json at all")
assert_contains "unparseable body is a clear 400" '"error":"invalid_json_body"' "$got"

got=$(post "not-a-uuid")
assert_contains "malformed uuid is caught before it reaches Postgres" \
  '"error":"membership_id_malformed"' "$got"

# ---------------------------------------------------------------------------
# 3. Nonexistent membership — errors cleanly, does not crash
# ---------------------------------------------------------------------------
printf '\n%s-- nonexistent membership --%s\n' "$B" "$N"

got=$(post "$GHOST_MEMBERSHIP")
assert_contains "unknown membership_id is reported, not guessed at" \
  '"error":"membership_not_found"' "$got"
assert_contains "unknown membership_id response is ok:false" '"ok":false' "$got"
assert_equals   "unknown membership_id returns 404, not 5xx" \
  "404" "$(post_status "$GHOST_MEMBERSHIP")"
assert_db "unknown membership created no payment row" \
  "0" "$(sql "select count(*) from payments where idempotency_key like 'renewal-%';")"
assert_db "unknown membership queued no message" \
  "0" "$(sql "select count(*) from whatsapp_messages where template_name='renewal_reminder';")"

# ---------------------------------------------------------------------------
# 4. Normal send — REAL Razorpay link, payment row, reminder message
# ---------------------------------------------------------------------------
printf '\n%s-- normal send (calls the real Razorpay API) --%s\n' "$B" "$N"

reset_state
period_end=$(sql "select current_period_end from memberships where id='$MEM_PAST_DUE';")
expected_key="renewal-$MEM_PAST_DUE-$period_end"

got=$(post "$MEM_PAST_DUE")

assert_contains "reminder reports created"        '"created":true' "$got"
assert_contains "response is ok"                  '"ok":true' "$got"
assert_contains "response carries the pay URL"    '"payment_url":"https://rzp.io/' "$got"
assert_contains "response carries the link id"    '"razorpay_link_id":"plink_' "$got"
assert_contains "amount is the plan price in rupees, not paise" '"amount":1500' "$got"
assert_contains "body_preview is the member-facing text" \
  '"body_preview":"Hi Bharat Rao, your Monthly Unlimited membership renews on ' "$got"
assert_contains "message contains the pay link"   'Pay here to continue: https://rzp.io/' "$got"

PAYMENT_ID=$(field payment_id "$got")
LINK_ID=$(field razorpay_link_id "$got")
PAY_URL=$(field payment_url "$got")

printf '\n  %sREAL RAZORPAY LINK CREATED%s — verify this in the dashboard:\n' "$B" "$N"
printf '    link id : %s\n    url     : %s\n\n' "${LINK_ID:-<none>}" "${PAY_URL:-<none>}"

if [ -n "$LINK_ID" ]; then
  case "$LINK_ID" in
    plink_*) ok "link id has Razorpay's plink_ prefix (it came from the API)" ;;
    *)       bad "link id has Razorpay's plink_ prefix (it came from the API)" "plink_*" "$LINK_ID" ;;
  esac
else
  bad "a Razorpay link id was returned" "plink_..." "(none)"
fi

# --- The payments row razorpay-webhook will reconcile ---
assert_db "exactly one payment row for this renewal period" \
  "1" "$(sql "select count(*) from payments where idempotency_key='$expected_key';")"
assert_db "idempotency_key is renewal-{membership}-{period_end}" \
  "$expected_key" "$(sql "select idempotency_key from payments where id='$PAYMENT_ID';")"
assert_db "payment status is pending" \
  "pending" "$(sql "select status from payments where id='$PAYMENT_ID';")"
assert_db "provider is razorpay" \
  "razorpay" "$(sql "select provider from payments where id='$PAYMENT_ID';")"
assert_db "amount stored in RUPEES (1500.00), paise only went to Razorpay" \
  "1500.00" "$(sql "select amount from payments where id='$PAYMENT_ID';")"
assert_db "razorpay_link_id was stored" \
  "$LINK_ID" "$(sql "select razorpay_link_id from payments where id='$PAYMENT_ID';")"
# The gap found in manual testing: razorpay_link_id is the ONLY handle the
# webhook has until a payment actually happens, so it must be non-null here...
assert_db "razorpay_link_id is NOT NULL — the webhook's only handle" \
  "f" "$(sql "select (razorpay_link_id is null) from payments where id='$PAYMENT_ID';")"
# ...and provider_payment_id must stay NULL for the webhook to backfill.
assert_db "provider_payment_id left NULL for the webhook to backfill" \
  "t" "$(sql "select (provider_payment_id is null) from payments where id='$PAYMENT_ID';")"
assert_db "reconciled_at left NULL (nothing is reconciled yet)" \
  "t" "$(sql "select (reconciled_at is null) from payments where id='$PAYMENT_ID';")"
assert_db "payment is scoped to the right tenant" \
  "$ORG_IRON" "$(sql "select organization_id from payments where id='$PAYMENT_ID';")"

# --- The whatsapp_messages row (send mocked by WHATSAPP_SEND_MODE=mock, real row) ---
assert_db "one outbound renewal_reminder was logged" \
  "1" "$(sql "select count(*) from whatsapp_messages where member_id='$MEMBER_PAST_DUE' and direction='outbound' and template_name='renewal_reminder';")"
assert_db "message status is queued" \
  "queued" "$(sql "select status from whatsapp_messages where related_payment_id='$PAYMENT_ID';")"
assert_db "message is linked to the new payment via related_payment_id" \
  "1" "$(sql "select count(*) from whatsapp_messages where related_payment_id='$PAYMENT_ID';")"
assert_db "message body carries the real payment link" \
  "1" "$(sql "select count(*) from whatsapp_messages where related_payment_id='$PAYMENT_ID' and body_preview like '%rzp.io%';")"
assert_db "wa_message_id is NULL (send was mocked, nothing was delivered)" \
  "t" "$(sql "select (wa_message_id is null) from whatsapp_messages where related_payment_id='$PAYMENT_ID';")"

# ---------------------------------------------------------------------------
# 5. Duplicate call the same day — guard #1, the anti-spam guard
# ---------------------------------------------------------------------------
printf '\n%s-- duplicate call, same day --%s\n' "$B" "$N"

got=$(post "$MEM_PAST_DUE")

assert_contains "second call today is skipped"  '"skipped":"already_sent_today"' "$got"
assert_contains "skip is still ok:true (not an error for renewal-scan)" '"ok":true' "$got"
assert_not_contains "skip returns no new payment url" 'payment_url' "$got"
assert_db "no second message was queued" \
  "1" "$(sql "select count(*) from whatsapp_messages where member_id='$MEMBER_PAST_DUE' and template_name='renewal_reminder';")"
assert_db "no second payment row was created" \
  "1" "$(sql "select count(*) from payments where idempotency_key like 'renewal-$MEM_PAST_DUE%';")"

# A third call must behave identically — the guard is not a one-shot.
got=$(post "$MEM_PAST_DUE")
assert_contains "third call today is also skipped" '"skipped":"already_sent_today"' "$got"

# ---------------------------------------------------------------------------
# 6. Same renewal period, a later day — guard #2, the money guard
#
# Clearing today's message re-opens guard #1 (this is what tomorrow looks like).
# Guard #2 must still hold: one payments row and ONE Razorpay link per renewal
# period, so a day-3 reminder does not create a second live payment link.
# ---------------------------------------------------------------------------
printf '\n%s-- same period, later day (reuse, do not re-charge) --%s\n' "$B" "$N"

if ! $have_psql; then
  skipped "reminder re-sent tomorrow reuses the payment row" "requires docker/psql"
else
  clear_todays_message "$MEMBER_PAST_DUE"
  got=$(post "$MEM_PAST_DUE")

  assert_contains "re-send reports reused, not created" '"reused":true' "$got"
  assert_equals   "re-send reuses the SAME payments row" "$PAYMENT_ID" "$(field payment_id "$got")"
  assert_equals   "re-send reuses the SAME Razorpay link" "$LINK_ID" "$(field razorpay_link_id "$got")"
  assert_equals   "re-send serves the SAME pay URL"       "$PAY_URL" "$(field payment_url "$got")"
  assert_db "still exactly one payment row for the period" \
    "1" "$(sql "select count(*) from payments where idempotency_key='$expected_key';")"
  assert_db "the re-send was logged as a new message" \
    "1" "$(sql "select count(*) from whatsapp_messages where member_id='$MEMBER_PAST_DUE' and template_name='renewal_reminder';")"
fi

# ---------------------------------------------------------------------------
# 7. Already paid — do not chase a member who has settled up
# ---------------------------------------------------------------------------
printf '\n%s-- already paid --%s\n' "$B" "$N"

if ! $have_psql; then
  skipped "a paid renewal is not chased again" "requires docker/psql"
else
  clear_todays_message "$MEMBER_PAST_DUE"
  sql "update payments set status='success', reconciled_at=now() where idempotency_key='$expected_key';" >/dev/null

  got=$(post "$MEM_PAST_DUE")
  assert_contains "a paid renewal is skipped" '"skipped":"already_paid"' "$got"
  assert_db "no reminder was queued for a paid renewal" \
    "0" "$(sql "select count(*) from whatsapp_messages where member_id='$MEMBER_PAST_DUE' and template_name='renewal_reminder';")"
  assert_db "the paid payment row was not duplicated" \
    "1" "$(sql "select count(*) from payments where idempotency_key='$expected_key';")"
fi

# ---------------------------------------------------------------------------
# 8. whatsapp_opt_in = false — consent guard
#
# Uses the FlexFit member so it is unaffected by the messages the cases above
# wrote for the Iron Temple member. Guard #1 is checked before this one, so a
# member who was already messaged today would mask the opt-out result.
# ---------------------------------------------------------------------------
printf '\n%s-- whatsapp_opt_in = false --%s\n' "$B" "$N"

reset_state

if ! $have_psql; then
  skipped "an opted-out member is not messaged" "requires docker/psql (needs to flip the flag)"
else
  sql "update members set whatsapp_opt_in=false where id='$MEMBER_OTHER_ORG';" >/dev/null

  got=$(post "$MEM_OTHER_ORG")

  assert_contains "opted-out member is skipped"  '"skipped":"whatsapp_opt_out"' "$got"
  assert_contains "opt-out skip is ok:true"      '"ok":true' "$got"
  assert_not_contains "opt-out skip created no pay URL" 'payment_url' "$got"

  # The important part: consent is checked BEFORE any side effect. No payment
  # link should exist at Razorpay for a member we are not allowed to message.
  assert_db "opted-out member got no payment row" \
    "0" "$(sql "select count(*) from payments where membership_id='$MEM_OTHER_ORG' and idempotency_key like 'renewal-%';")"
  assert_db "opted-out member got no message row" \
    "0" "$(sql "select count(*) from whatsapp_messages where member_id='$MEMBER_OTHER_ORG';")"

  # Re-opting in must work immediately — the skip is not sticky state.
  sql "update members set whatsapp_opt_in=true where id='$MEMBER_OTHER_ORG';" >/dev/null
  got=$(post "$MEM_OTHER_ORG")
  assert_contains "re-opted-in member is messaged" '"created":true' "$got"
  assert_contains "other tenant's plan price is used (₹2000)" '"amount":2000' "$got"

  optin_link=$(field razorpay_link_id "$got")
  optin_url=$(field payment_url "$got")
  printf '\n  %sREAL RAZORPAY LINK CREATED%s (FlexFit / ₹2000):\n' "$B" "$N"
  printf '    link id : %s\n    url     : %s\n\n' "${optin_link:-<none>}" "${optin_url:-<none>}"

  assert_db "the second tenant's payment is scoped to the second tenant" \
    "22222222-2222-2222-2222-222222222222" \
    "$(sql "select organization_id from payments where membership_id='$MEM_OTHER_ORG' and idempotency_key like 'renewal-%';")"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
reset_state

printf '\n%s== summary ==%s\n' "$B" "$N"
printf '  %spassed %d%s   %sfailed %d%s   %sskipped %d%s\n' "$G" "$PASS" "$N" "$R" "$FAIL" "$N" "$Y" "$SKIP" "$N"
printf '  note: the Razorpay TEST MODE links printed above still exist in your\n'
printf '        dashboard. They are unpaid and were never sent to anyone.\n'

if [ "$FAIL" -gt 0 ]; then
  printf '\n  failing cases:\n'
  for c in "${FAILED_CASES[@]}"; do printf '    - %s\n' "$c"; done
  printf '\n'
  exit 1
fi

printf '\n'
exit 0
