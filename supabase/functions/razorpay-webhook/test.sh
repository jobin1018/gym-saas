#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Mock-Razorpay integration tests for the razorpay-webhook Edge Function.
#
# Simulates Razorpay delivering webhooks with CORRECTLY COMPUTED
# X-Razorpay-Signature headers (real HMAC-SHA256 over the raw body), and asserts
# PASS/FAIL on the response shape plus the resulting database state.
#
# NOTE: unlike its name, "Mock-Razorpay" refers only to Razorpay being
# simulated by this script (there is no real Razorpay account involved). The
# outbound WhatsApp send this function triggers on payment.captured /
# payment_link.paid / payment.failed is REAL (via ../_shared/whatsapp.ts, same
# as send-renewal-reminder and daily-owner-brief), so this suite forces
# WHATSAPP_SEND_MODE=mock (checked in preflight below) the same way those two
# suites do.
#
# PREREQUISITES
#   1. supabase start
#   2. supabase db reset                 # applies migrations + seed.sql
#   3. supabase functions serve razorpay-webhook --env-file supabase/functions/.env
#   4. bash supabase/functions/razorpay-webhook/test.sh
#
# Requires: curl, openssl, docker (for DB assertions).
# Fixtures come from supabase/seed.sql; the suite re-pins them before each group
# so it is safe to run repeatedly.
# ---------------------------------------------------------------------------

set -uo pipefail

BASE_URL="${BASE_URL:-http://127.0.0.1:54321/functions/v1/razorpay-webhook}"
ENV_FILE="${ENV_FILE:-$(dirname "$0")/../.env}"
DB_CONTAINER="${DB_CONTAINER:-supabase_db_gym-saas}"

# Seeded fixtures (see supabase/seed.sql)
PAY_CAPTURED=a1111111-1111-1111-1111-111111111111   # provider_payment_id pay_TEST_CAPTURED
PAY_FAILED=a2222222-2222-2222-2222-222222222222     # provider_payment_id pay_TEST_FAILED
PAY_LINK=a3333333-3333-3333-3333-333333333333       # razorpay_link_id plink_TEST_LINK
MEM_ACTIVE=f1111111-1111-1111-1111-111111111111     # active,   ends CURRENT_DATE + 20
MEM_PAST_DUE=f2222222-2222-2222-2222-222222222222   # past_due, ends CURRENT_DATE - 10
MEM_LINK=f3333333-3333-3333-3333-333333333333       # active,   ends CURRENT_DATE + 25

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
WA_SEND_MODE="${WHATSAPP_SEND_MODE:-$(read_env WHATSAPP_SEND_MODE)}"

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

assert_equals() {
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "$2" "$3"; fi
}

# ---------------------------------------------------------------------------
# Mock Razorpay transport
# ---------------------------------------------------------------------------

sign() { printf '%s' "$1" | openssl dgst -sha256 -hmac "$WEBHOOK_SECRET" | sed 's/^.*= *//'; }

# payment_event <event> <event_id> <pay_id> <amount_paise>
# Razorpay's documented envelope; amounts are integer PAISE.
payment_event() {
  printf '{"entity":"event","account_id":"acc_TEST","event":"%s","id":"%s","contains":["payment"],"payload":{"payment":{"entity":{"id":"%s","entity":"payment","amount":%s,"currency":"INR","status":"captured","method":"upi","captured":true}}},"created_at":1767225600}' \
    "$1" "$2" "$3" "$4"
}

# link_event <event_id> <plink_id> <pay_id> <amount_paise>
link_event() {
  printf '{"entity":"event","account_id":"acc_TEST","event":"payment_link.paid","id":"%s","contains":["payment_link","payment"],"payload":{"payment_link":{"entity":{"id":"%s","entity":"payment_link","amount":%s,"status":"paid"}},"payment":{"entity":{"id":"%s","entity":"payment","amount":%s,"currency":"INR","status":"captured"}}},"created_at":1767225600}' \
    "$1" "$2" "$4" "$3" "$4"
}

# post <body> [signature-mode] -> response body
#   signature-mode: VALID (default) | NONE | <literal header value>
post() {
  local body="$1" mode="${2:-VALID}"
  local args=(-s -X POST "$BASE_URL" -H 'Content-Type: application/json')

  if [ "$mode" = "VALID" ]; then
    args+=(-H "X-Razorpay-Signature: $(sign "$body")")
  elif [ "$mode" != "NONE" ]; then
    args+=(-H "X-Razorpay-Signature: $mode")
  fi

  curl "${args[@]}" -d "$body"
}

# post_status <body> [signature-mode] -> HTTP status code
post_status() {
  local body="$1" mode="${2:-VALID}"
  local args=(-s -o /dev/null -w '%{http_code}' -X POST "$BASE_URL" -H 'Content-Type: application/json')

  if [ "$mode" = "VALID" ]; then
    args+=(-H "X-Razorpay-Signature: $(sign "$body")")
  elif [ "$mode" != "NONE" ]; then
    args+=(-H "X-Razorpay-Signature: $mode")
  fi

  curl "${args[@]}" -d "$body"
}

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

# Restore fixtures to their seeded state. whatsapp_messages must go first:
# related_payment_id references payments.
reset_state() {
  $have_psql || return 0
  docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -q >/dev/null 2>&1 <<SQL
TRUNCATE whatsapp_messages, webhook_events;
UPDATE payments SET status='pending', reconciled_at=NULL,
       provider_payment_id='pay_TEST_CAPTURED', razorpay_link_id=NULL
 WHERE id='$PAY_CAPTURED';
UPDATE payments SET status='pending', reconciled_at=NULL,
       provider_payment_id='pay_TEST_FAILED', razorpay_link_id=NULL
 WHERE id='$PAY_FAILED';
UPDATE payments SET status='pending', reconciled_at=NULL,
       provider_payment_id=NULL, razorpay_link_id='plink_TEST_LINK'
 WHERE id='$PAY_LINK';
UPDATE memberships SET status='active',   current_period_end=CURRENT_DATE + 20 WHERE id='$MEM_ACTIVE';
UPDATE memberships SET status='past_due', current_period_end=CURRENT_DATE - 10 WHERE id='$MEM_PAST_DUE';
UPDATE memberships SET status='active',   current_period_end=CURRENT_DATE + 25 WHERE id='$MEM_LINK';
SQL
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

printf '\n%s== mock-razorpay webhook tests ==%s\n' "$B" "$N"
printf 'target: %s\n' "$BASE_URL"

if [ "$(printf '%s' "$WA_SEND_MODE" | tr '[:upper:]' '[:lower:]')" != "mock" ]; then
  printf '\n%sREFUSING TO RUN%s WHATSAPP_SEND_MODE is not "mock" in %s (got: %s).\n' \
    "$R" "$N" "$ENV_FILE" "${WA_SEND_MODE:-<unset>}"
  printf '        This suite triggers payment.captured/payment_link.paid/payment.failed,\n'
  printf '        each of which calls sendWhatsAppMessage(), which hits the real Meta Cloud\n'
  printf '        API LIVE by default. Set WHATSAPP_SEND_MODE=mock in %s and restart\n' "$ENV_FILE"
  printf '        `supabase functions serve` before running this suite, or it will send real\n'
  printf '        WhatsApp messages to the seeded member phone numbers.\n\n'
  exit 1
fi

if ! command -v openssl >/dev/null 2>&1; then
  printf '\n%sERROR%s openssl is required to compute X-Razorpay-Signature.\n\n' "$R" "$N"
  exit 1
fi

if [ -z "$WEBHOOK_SECRET" ]; then
  printf '\n%sERROR%s no RAZORPAY_WEBHOOK_SECRET found in %s\n' "$R" "$N" "$ENV_FILE"
  printf '        The function fails closed without it (500, by design).\n\n'
  exit 1
fi

if ! curl -s -o /dev/null --max-time 5 -X POST "$BASE_URL" -d '{}'; then
  printf '\n%sERROR%s cannot reach the function. Start it with:\n' "$R" "$N"
  printf '  supabase functions serve razorpay-webhook --env-file supabase/functions/.env\n\n'
  exit 1
fi

if $have_psql; then
  if [ "$(sql "select count(*) from payments where id='$PAY_CAPTURED';")" != "1" ]; then
    printf '\n%sERROR%s payment fixtures missing. Run: supabase db reset\n\n' "$R" "$N"
    exit 1
  fi
else
  printf '%swarn%s  docker/psql unavailable — database assertions will SKIP\n' "$Y" "$N"
fi

# Confirm the secret we sign with matches the one the function verifies with,
# before attributing any later failure to business logic.
probe=$(post_status "$(payment_event "probe.event" "evt_probe_$$" "pay_probe" 100)")
if [ "$probe" = "500" ]; then
  printf '\n%sERROR%s function returned 500: RAZORPAY_WEBHOOK_SECRET not set in its environment.\n' "$R" "$N"
  printf '        Restart serve with --env-file supabase/functions/.env\n\n'
  exit 1
fi
if [ "$probe" = "400" ]; then
  printf '\n%sERROR%s function rejected a correctly-signed probe (400).\n' "$R" "$N"
  printf '        The secret in %s does not match the one serve was started with.\n\n' "$ENV_FILE"
  exit 1
fi

RUN=$$-$(date +%s)   # unique per run: (source, event_id) is UNIQUE
reset_state

# ---------------------------------------------------------------------------
# 1. Signature verification
# ---------------------------------------------------------------------------
printf '\n%s-- signature verification --%s\n' "$B" "$N"

body=$(payment_event "payment.captured" "evt_$RUN.sig" "pay_TEST_CAPTURED" 150000)

got=$(post_status "$body" "0000000000000000000000000000000000000000000000000000000000000000")
assert_equals "invalid signature is rejected 400" "400" "$got"

got=$(post_status "$body" "NONE")
assert_equals "missing signature header is rejected 400" "400" "$got"

got=$(post "$body" "deadbeef")
assert_contains "rejection body says invalid_signature" '"error":"invalid_signature"' "$got"

# Requirement 1: an unverified payload is not a real event and must never be stored.
assert_db "rejected delivery wrote NO webhook_events row" \
  "0" "$(sql "select count(*) from webhook_events where event_id='evt_$RUN.sig';")"
assert_db "rejected delivery did NOT touch the payment" \
  "pending" "$(sql "select status from payments where id='$PAY_CAPTURED';")"

got=$(post_status "$body" "VALID")
assert_equals "correctly-signed delivery is accepted 200" "200" "$got"

# ---------------------------------------------------------------------------
# 2. payment.captured — the success path
# ---------------------------------------------------------------------------
printf '\n%s-- payment.captured --%s\n' "$B" "$N"

reset_state
expected_end=$(sql "select (CURRENT_DATE + 20 + interval '1 month')::date;")

body=$(payment_event "payment.captured" "evt_$RUN.cap" "pay_TEST_CAPTURED" 150000)
got=$(post "$body")

assert_contains "payment.captured is handled"        '"handled":"payment_success"' "$got"
assert_contains "matched by provider_payment_id"     '"matched_by":"provider_payment_id"' "$got"
assert_db "payment marked success"                   "success" "$(sql "select status from payments where id='$PAY_CAPTURED';")"
assert_db "reconciled_at was stamped"                "1" "$(sql "select (reconciled_at is not null)::int from payments where id='$PAY_CAPTURED';")"
assert_db "membership set active"                    "active" "$(sql "select status from memberships where id='$MEM_ACTIVE';")"
assert_db "period extended 1 month from the later of today/current end" \
  "$expected_end" "$(sql "select current_period_end from memberships where id='$MEM_ACTIVE';")"
assert_db "confirmation message queued with related_payment_id" \
  "1" "$(sql "select count(*) from whatsapp_messages where direction='outbound' and status='queued' and related_payment_id='$PAY_CAPTURED';")"
# MEM_ACTIVE (PAY_CAPTURED) is Asha Menon, plan "Monthly Unlimited", ₹1500 —
# see seed.sql. body_preview is the human-readable audit text (mirrors, but
# need not byte-match, the approved payment_confirmation template Meta itself
# renders — see the comment on MESSAGE.paymentReceived).
assert_db "confirmation names the member, amount and plan" \
  "1" "$(sql "select count(*) from whatsapp_messages where related_payment_id='$PAY_CAPTURED' and body_preview like 'Hi Asha Menon, we%received your payment of %1,500%Monthly Unlimited%';")"
assert_db "confirmation uses the approved payment_confirmation template" \
  "1" "$(sql "select count(*) from whatsapp_messages where related_payment_id='$PAY_CAPTURED' and template_name='payment_confirmation';")"
assert_db "webhook_events marked processed"          "t" "$(sql "select processed from webhook_events where event_id='evt_$RUN.cap';")"

# Paying early must ADD a month, not truncate to today+1month.
assert_db "early payment did not shorten the period" \
  "t" "$(sql "select (current_period_end > CURRENT_DATE + interval '1 month')::bool from memberships where id='$MEM_ACTIVE';")"

# ---------------------------------------------------------------------------
# 3. Duplicate event replay
# ---------------------------------------------------------------------------
printf '\n%s-- duplicate replay --%s\n' "$B" "$N"

end_before=$(sql "select current_period_end from memberships where id='$MEM_ACTIVE';")

got=$(post "$body")   # byte-identical resend of the captured event
assert_contains "replayed event returns duplicate" '"duplicate":true' "$got"
assert_db "replayed event did NOT extend the period again" \
  "$end_before" "$(sql "select current_period_end from memberships where id='$MEM_ACTIVE';")"
assert_db "replayed event stored only once" \
  "1" "$(sql "select count(*) from webhook_events where event_id='evt_$RUN.cap';")"
assert_db "replayed event queued no second message" \
  "1" "$(sql "select count(*) from whatsapp_messages where related_payment_id='$PAY_CAPTURED';")"

# Defence in depth: a NEW event id for an already-'success' payment must still
# be a no-op, independent of the webhook_events guard.
got=$(post "$(payment_event "payment.captured" "evt_$RUN.cap2" "pay_TEST_CAPTURED" 150000)")
assert_contains "already-success payment is an idempotent no-op" '"skipped":"already_success"' "$got"
assert_db "already-success no-op did not extend the period" \
  "$end_before" "$(sql "select current_period_end from memberships where id='$MEM_ACTIVE';")"

# ---------------------------------------------------------------------------
# 4. payment.failed
# ---------------------------------------------------------------------------
printf '\n%s-- payment.failed --%s\n' "$B" "$N"

reset_state
end_before=$(sql "select current_period_end from memberships where id='$MEM_PAST_DUE';")

got=$(post "$(payment_event "payment.failed" "evt_$RUN.fail" "pay_TEST_FAILED" 150000)")

assert_contains "payment.failed is handled"  '"handled":"payment_failed"' "$got"
assert_db "payment marked failed"            "failed" "$(sql "select status from payments where id='$PAY_FAILED';")"
assert_db "membership status left UNCHANGED" "past_due" "$(sql "select status from memberships where id='$MEM_PAST_DUE';")"
assert_db "membership period left UNCHANGED" "$end_before" "$(sql "select current_period_end from memberships where id='$MEM_PAST_DUE';")"
assert_db "failure notice queued"            "1" "$(sql "select count(*) from whatsapp_messages where related_payment_id='$PAY_FAILED' and body_preview like 'We couldn''t process%';")"
# payment_failed has no approved template yet (TODO(meta) in index.ts) — this
# must still be a real send, just free-form text, not a template call.
assert_db "failure notice is free-form (no approved template yet)" \
  "1" "$(sql "select count(*) from whatsapp_messages where related_payment_id='$PAY_FAILED' and template_name is null;")"
assert_db "failure event marked processed"   "t" "$(sql "select processed from webhook_events where event_id='evt_$RUN.fail';")"

# ---------------------------------------------------------------------------
# 5. Unknown provider_payment_id — graceful, not a crash
# ---------------------------------------------------------------------------
printf '\n%s-- unmatched payment --%s\n' "$B" "$N"

reset_state
got=$(post "$(payment_event "payment.captured" "evt_$RUN.ghost" "pay_DOES_NOT_EXIST" 150000)")

assert_contains "unmatched payment is skipped gracefully" '"skipped":"payment_not_found"' "$got"
assert_contains "unmatched payment still returns ok"      '"ok":true' "$got"
got=$(post_status "$(payment_event "payment.captured" "evt_$RUN.ghost2" "pay_DOES_NOT_EXIST_2" 150000)")
assert_equals   "unmatched payment returns 200, not 5xx"  "200" "$got"
assert_db "unmatched event still marked processed" \
  "t" "$(sql "select processed from webhook_events where event_id='evt_$RUN.ghost';")"
# Scoped to this suite's own 3 known fixtures, not a global count — seed.sql
# now seeds realistic 'success' payment history elsewhere (for v_daily_revenue
# manual testing), so a global "zero success rows anywhere" check would fail
# for reasons unrelated to what this assertion actually verifies: that an
# unattributable event didn't corrupt one of THIS suite's own rows.
assert_db "unmatched event changed none of this suite's own payment rows" \
  "0" "$(sql "select count(*) from payments where status='success' and id in ('$PAY_CAPTURED','$PAY_FAILED','$PAY_LINK');")"

# ---------------------------------------------------------------------------
# 6. payment_link.paid — matched by razorpay_link_id
# ---------------------------------------------------------------------------
printf '\n%s-- payment_link.paid --%s\n' "$B" "$N"

reset_state
expected_end=$(sql "select (CURRENT_DATE + 25 + interval '1 month')::date;")

got=$(post "$(link_event "evt_$RUN.link" "plink_TEST_LINK" "pay_FROM_LINK" 150000)")

assert_contains "payment_link.paid is handled"     '"handled":"payment_success"' "$got"
assert_contains "fell back to razorpay_link_id"    '"matched_by":"razorpay_link_id"' "$got"
assert_db "provider_payment_id was backfilled"     "pay_FROM_LINK" "$(sql "select provider_payment_id from payments where id='$PAY_LINK';")"
assert_db "link payment marked success"            "success" "$(sql "select status from payments where id='$PAY_LINK';")"
assert_db "link membership period extended"        "$expected_end" "$(sql "select current_period_end from memberships where id='$MEM_LINK';")"

# ---------------------------------------------------------------------------
# 7. Forward compatibility
# ---------------------------------------------------------------------------
printf '\n%s-- unhandled event types --%s\n' "$B" "$N"

reset_state
got=$(post "$(payment_event "subscription.charged" "evt_$RUN.sub" "pay_TEST_CAPTURED" 150000)")

assert_contains "unhandled event type is ignored, not an error" '"handled":"ignored"' "$got"
assert_db "unhandled event took no action" "pending" "$(sql "select status from payments where id='$PAY_CAPTURED';")"
assert_db "unhandled event marked processed" "t" "$(sql "select processed from webhook_events where event_id='evt_$RUN.sub';")"

got=$(post 'not json at all')
assert_contains "signed-but-unparseable body is acked, not crashed" '"ignored":"unparseable_body"' "$got"

got=$(curl -s -X GET "$BASE_URL")
assert_contains "GET is rejected (Razorpay only POSTs)" 'method_not_allowed' "$got"

# ---------------------------------------------------------------------------
# 8. NOTES-BASED FALLBACK LOOKUP (tiers 3 and 4)
#
# THE GAP THIS CLOSES. A `payment.failed` carries only payload.payment.entity —
# no payment_link block — and the matching payments row still has
# provider_payment_id NULL, because that column is only backfilled when a
# payment SUCCEEDS. So both original lookup tiers missed, the row stayed
# 'pending' forever, and nobody was told the payment had failed.
#
# BEFORE/AFTER IS TESTED SIDE BY SIDE BELOW. The "before" behaviour is not
# described from memory — it is exercised directly, by sending the identical
# payload with its `notes` removed. That variant must still report
# payment_not_found; the variant WITH notes must reconcile. Same event shape,
# one field apart.
# ---------------------------------------------------------------------------
printf '\n%s-- notes fallback lookup --%s\n' "$B" "$N"

reset_state

ORG_IRON=11111111-1111-1111-1111-111111111111
ORG_FLEX=22222222-2222-2222-2222-222222222222

# payment_event_notes <event> <event_id> <pay_id> <amount_paise> <notes_json>
# Same envelope as payment_event(), plus the `notes` object Razorpay echoes back
# from the payment link that created the payment.
payment_event_notes() {
  printf '{"entity":"event","account_id":"acc_TEST","event":"%s","id":"%s","contains":["payment"],"payload":{"payment":{"entity":{"id":"%s","entity":"payment","amount":%s,"currency":"INR","status":"failed","method":"upi","notes":%s}}},"created_at":1767225600}' \
    "$1" "$2" "$3" "$4" "$5"
}

# --- BEFORE: no notes, no link id, unknown payment id -> unmatched ---
got=$(post "$(payment_event_notes "payment.failed" "evt_$RUN.nf1" "pay_UNSEEN_1" 150000 '{}')")

assert_contains "BEFORE: a link-less failure with no notes is still unmatched" \
  '"skipped":"payment_not_found"' "$got"
assert_db "BEFORE: the payment row was left pending" \
  "pending" "$(sql "select status from payments where id='$PAY_FAILED';")"

# --- AFTER: same payload + notes.idempotency_key -> exact match (tier 3) ---
got=$(post "$(payment_event_notes "payment.failed" "evt_$RUN.nf2" "pay_UNSEEN_2" 150000 \
  "{\"organization_id\":\"$ORG_IRON\",\"membership_id\":\"$MEM_PAST_DUE\",\"idempotency_key\":\"seed-idem-failed\"}")")

assert_contains "AFTER: the same failure WITH notes is reconciled" \
  '"handled":"payment_failed"' "$got"
assert_contains "AFTER: matched via notes.idempotency_key" \
  '"matched_by":"notes_idempotency_key"' "$got"
assert_db "AFTER: the payment row was marked failed" \
  "failed" "$(sql "select status from payments where id='$PAY_FAILED';")"
assert_db "AFTER: the member was told the payment failed" \
  "1" "$(sql "select count(*) from whatsapp_messages where related_payment_id='$PAY_FAILED';")"
assert_db "AFTER: membership status was still left alone (dunning is not a webhook's job)" \
  "past_due" "$(sql "select status from memberships where id='$MEM_PAST_DUE';")"

# --- Tier 4: membership_id + organization_id, no idempotency_key ---
# PAY_LINK is the only pending payment on MEM_LINK and has provider_payment_id
# NULL, so tiers 1-3 all miss and tier 4 is the one under test.
reset_state
got=$(post "$(payment_event_notes "payment.failed" "evt_$RUN.nf3" "pay_UNSEEN_3" 150000 \
  "{\"organization_id\":\"$ORG_IRON\",\"membership_id\":\"$MEM_LINK\"}")")

assert_contains "tier 4: matched via notes.membership_id" \
  '"matched_by":"notes_membership_id"' "$got"
assert_db "tier 4: the right payment row was marked failed" \
  "failed" "$(sql "select status from payments where id='$PAY_LINK';")"
assert_db "tier 4: it did NOT touch another member's pending payment" \
  "pending" "$(sql "select status from payments where id='$PAY_CAPTURED';")"

# --- Tier 4 safety: membership_id WITHOUT organization_id must not widen ---
reset_state
got=$(post "$(payment_event_notes "payment.failed" "evt_$RUN.nf4" "pay_UNSEEN_4" 150000 \
  "{\"membership_id\":\"$MEM_LINK\"}")")

assert_contains "safety: membership_id alone is NOT enough to match" \
  '"skipped":"payment_not_found"' "$got"
assert_db "safety: nothing was reconciled without a tenant to scope to" \
  "pending" "$(sql "select status from payments where id='$PAY_LINK';")"

# --- Tier 4 safety: the tenant in the notes must actually own the membership ---
reset_state
got=$(post "$(payment_event_notes "payment.failed" "evt_$RUN.nf5" "pay_UNSEEN_5" 150000 \
  "{\"organization_id\":\"$ORG_FLEX\",\"membership_id\":\"$MEM_LINK\"}")")

assert_contains "safety: a cross-tenant notes pair matches nothing" \
  '"skipped":"payment_not_found"' "$got"
assert_db "safety: the other tenant's payment was untouched" \
  "pending" "$(sql "select status from payments where id='$PAY_LINK';")"

# --- The success path benefits too, not just failures ---
reset_state
expected_end=$(sql "select (CURRENT_DATE + 25 + interval '1 month')::date;")
got=$(post "$(payment_event_notes "payment.captured" "evt_$RUN.nf6" "pay_NOTES_OK" 150000 \
  "{\"organization_id\":\"$ORG_IRON\",\"membership_id\":\"$MEM_LINK\",\"idempotency_key\":\"seed-idem-link\"}")")

assert_contains "a captured payment with only notes is reconciled" \
  '"handled":"payment_success"' "$got"
assert_contains "captured-by-notes matched on idempotency_key" \
  '"matched_by":"notes_idempotency_key"' "$got"
assert_db "captured-by-notes backfilled provider_payment_id" \
  "pay_NOTES_OK" "$(sql "select provider_payment_id from payments where id='$PAY_LINK';")"
assert_db "captured-by-notes extended the membership period" \
  "$expected_end" "$(sql "select current_period_end from memberships where id='$MEM_LINK';")"

# --- Tier precedence: a real payment id still wins over notes ---
# Notes here point at a DIFFERENT payment row than provider_payment_id does. The
# more exact tier must win, or the fallback would be able to misroute a payload
# that was already matching correctly.
reset_state
got=$(post "$(payment_event "payment.captured" "evt_$RUN.nf7" "pay_TEST_CAPTURED" 150000)")
assert_contains "precedence: provider_payment_id still wins when present" \
  '"matched_by":"provider_payment_id"' "$got"

reset_state
got=$(post "$(printf '{"entity":"event","account_id":"acc_TEST","event":"payment.captured","id":"evt_%s.nf8","contains":["payment"],"payload":{"payment":{"entity":{"id":"pay_TEST_CAPTURED","entity":"payment","amount":150000,"currency":"INR","status":"captured","captured":true,"notes":{"organization_id":"%s","membership_id":"%s","idempotency_key":"seed-idem-link"}}}},"created_at":1767225600}' "$RUN" "$ORG_IRON" "$MEM_LINK")")

assert_contains "precedence: notes do not override a known payment id" \
  '"matched_by":"provider_payment_id"' "$got"
assert_db "precedence: the payment id's row was the one reconciled" \
  "success" "$(sql "select status from payments where id='$PAY_CAPTURED';")"
assert_db "precedence: the row named only by notes was NOT touched" \
  "pending" "$(sql "select status from payments where id='$PAY_LINK';")"

# --- Unattributable payments still land in the error log, as designed ---
reset_state
got=$(post "$(payment_event_notes "payment.failed" "evt_$RUN.nf9" "pay_TOTALLY_UNKNOWN" 150000 \
  '{"some_other_note":"from a dashboard link"}')")

assert_contains "a payment with unrelated notes is still unattributable" \
  '"skipped":"payment_not_found"' "$got"
assert_contains "unattributable payments are still acked, not retried forever" '"ok":true' "$got"

# ---------------------------------------------------------------------------
# 11. Multi-month membership — current_period_end extends by the MEMBERSHIP's
#     duration_months, not 1, and not anything on the plan
# ---------------------------------------------------------------------------
printf '\n%s-- multi-month membership period extension --%s\n' "$B" "$N"
reset_state

# Throwaway fixture, fully self-contained: an ordinary (monthly-rate) plan, a
# membership on it with duration_months = 3, and a pending payment. Torn down
# at the end of this section so nothing else sees it. duration lives on the
# membership now (20260829099000), NOT the plan.
Q_ORG=11111111-1111-1111-1111-111111111111
Q_PLAN=d0000000-0000-0000-0000-0000000000d1
Q_MEM=d0000000-0000-0000-0000-0000000000d2
Q_PAY=d0000000-0000-0000-0000-0000000000d3
docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -q >/dev/null 2>&1 <<SQL
INSERT INTO membership_plans (id, organization_id, name, amount)
VALUES ('$Q_PLAN','$Q_ORG','Quarterly Test Plan', 4000)
ON CONFLICT (id) DO UPDATE SET amount = 4000;
INSERT INTO memberships (id, organization_id, member_id, plan_id, status, start_date, current_period_end, duration_months)
VALUES ('$Q_MEM','$Q_ORG','e1111111-1111-1111-1111-111111111111','$Q_PLAN','active', CURRENT_DATE, CURRENT_DATE + 30, 3)
ON CONFLICT (id) DO UPDATE SET status='active', current_period_end = CURRENT_DATE + 30, plan_id = '$Q_PLAN', duration_months = 3;
INSERT INTO payments (id, organization_id, membership_id, amount, provider, provider_payment_id, status, idempotency_key)
VALUES ('$Q_PAY','$Q_ORG','$Q_MEM', 4000, 'razorpay', 'pay_QUARTERLY_TEST', 'pending', 'razpay-test-quarterly')
ON CONFLICT (id) DO UPDATE SET status='pending', reconciled_at=NULL, provider_payment_id='pay_QUARTERLY_TEST';
SQL

expected_3mo=$(sql "select (CURRENT_DATE + 30 + interval '3 months')::date;")
one_month=$(sql "select (CURRENT_DATE + 30 + interval '1 month')::date;")

got=$(post "$(payment_event "payment.captured" "evt_$RUN.q3" "pay_QUARTERLY_TEST" 400000)")
assert_contains "3-month-membership capture is handled"        '"handled":"payment_success"' "$got"

new_end=$(sql "select current_period_end from memberships where id='$Q_MEM';")
assert_db "membership.duration_months=3 extends current_period_end by 3 months" "$expected_3mo" "$new_end"
if [ "$new_end" = "$one_month" ]; then
  bad "3-month membership did NOT fall back to the old +1-month behaviour" "$expected_3mo" "$new_end"
else
  ok "3-month membership did NOT fall back to the old +1-month behaviour"
fi

# total_price is a SIGNUP SNAPSHOT: the derive trigger set it to
# amount(4000) x duration_months(3) at insert...
assert_db "membership total_price snapshots amount x duration_months (12000)" \
  "12000.00" "$(sql "select total_price from memberships where id='$Q_MEM';")"
# ...and it does NOT drift when the plan's monthly rate later changes.
sql "update membership_plans set amount = 5000 where id='$Q_PLAN';" >/dev/null
assert_db "total_price stays frozen after a plan rate change (still 12000, not 15000)" \
  "12000.00" "$(sql "select total_price from memberships where id='$Q_MEM';")"

docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -q >/dev/null 2>&1 <<SQL
DELETE FROM whatsapp_messages WHERE related_payment_id='$Q_PAY';
DELETE FROM webhook_events   WHERE event_id = 'evt_$RUN.q3';
DELETE FROM payments         WHERE id='$Q_PAY';
DELETE FROM memberships      WHERE id='$Q_MEM';
DELETE FROM membership_plans WHERE id='$Q_PLAN';
SQL

# ---------------------------------------------------------------------------
# 12. PT-package payment — reconciled like a membership payment, but with NO
#     period to extend (20260829101000)
# ---------------------------------------------------------------------------
printf '\n%s-- PT-package payment reconciliation --%s\n' "$B" "$N"
reset_state

PT_PKG=d0000000-0000-0000-0000-0000000000e1
PT_PAY=d0000000-0000-0000-0000-0000000000e2
docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -q >/dev/null 2>&1 <<SQL
-- price 0 keeps the pt_packages_record_payment trigger out of the way; this
-- test drives the Razorpay pending -> success path explicitly.
INSERT INTO pt_packages (id, organization_id, member_id, coach_id, goal,
                         duration_months, sessions_per_month, sessions_purchased, price, status, start_date)
VALUES ('$PT_PKG','$ORG_IRON','e1111111-1111-1111-1111-111111111111',
        'c0ac0000-0000-0000-0000-000000000001','fat_loss',3,4,12,0,'active',CURRENT_DATE)
ON CONFLICT (id) DO NOTHING;
INSERT INTO payments (id, organization_id, membership_id, pt_package_id, amount, provider,
                      provider_payment_id, status, idempotency_key)
VALUES ('$PT_PAY','$ORG_IRON',NULL,'$PT_PKG',3000,'razorpay',NULL,'pending','razpay-test-ptpkg')
ON CONFLICT (id) DO UPDATE SET status='pending', reconciled_at=NULL, provider_payment_id=NULL;
SQL

pt_notes="{\"organization_id\":\"$ORG_IRON\",\"pt_package_id\":\"$PT_PKG\",\"idempotency_key\":\"razpay-test-ptpkg\"}"
pt_body=$(printf '{"entity":"event","account_id":"acc_TEST","event":"payment.captured","id":"evt_%s.pt","contains":["payment"],"payload":{"payment":{"entity":{"id":"pay_PT_TEST","entity":"payment","amount":300000,"currency":"INR","status":"captured","method":"upi","notes":%s}}},"created_at":1767225600}' "$RUN" "$pt_notes")

got=$(post "$pt_body")
assert_contains "PT-package capture is handled"                 '"handled":"payment_success"' "$got"
assert_contains "  ...identified as a PT-package payment"       '"subject":"pt_package"' "$got"
assert_contains "  ...no membership period was extended"        '"new_period_end":null' "$got"
assert_db "the PT payment row is now success"                   "success"      "$(sql "select status from payments where id='$PT_PAY';")"
assert_db "  ...reconciled_at was stamped"                      "1"            "$(sql "select (reconciled_at is not null)::int from payments where id='$PT_PAY';")"
assert_db "  ...provider_payment_id backfilled"                 "pay_PT_TEST"  "$(sql "select provider_payment_id from payments where id='$PT_PAY';")"
assert_db "  ...the pt_package itself was NOT touched"          "active"       "$(sql "select status from pt_packages where id='$PT_PKG';")"
assert_db "a confirmation was queued for the PT payment"        "1" "$(sql "select count(*) from whatsapp_messages where related_payment_id='$PT_PAY';")"
assert_db "  ...free-form (no pt_payment_confirmation template yet)" "1" "$(sql "select count(*) from whatsapp_messages where related_payment_id='$PT_PAY' and template_name is null;")"

got=$(post "$pt_body")
assert_contains "replayed PT event is a duplicate no-op"        '"duplicate":true' "$got"

docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -q >/dev/null 2>&1 <<SQL
DELETE FROM whatsapp_messages WHERE related_payment_id='$PT_PAY';
DELETE FROM webhook_events   WHERE event_id = 'evt_$RUN.pt';
DELETE FROM payments         WHERE id='$PT_PAY';
DELETE FROM pt_packages      WHERE id='$PT_PKG';
SQL

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
