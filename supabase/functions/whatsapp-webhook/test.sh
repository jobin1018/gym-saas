#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Mock-Meta integration tests for the whatsapp-webhook Edge Function.
#
# Simulates Meta's WhatsApp Cloud API calling your webhook — both the GET
# verification handshake and signed POST message deliveries — and asserts
# PASS/FAIL on the response shape plus the resulting database state.
#
# PREREQUISITES
#   1. supabase start
#   2. supabase db reset                 # applies migrations + seed.sql
#   3. supabase functions serve whatsapp-webhook --env-file supabase/functions/.env
#   4. bash supabase/functions/whatsapp-webhook/test.sh
#
# The test phone numbers come from supabase/seed.sql. Run `supabase db reset`
# if the members table is empty.
#
# SIGNATURE MODE is auto-detected by probing the running function:
#   enforcing  → every request is signed with META_APP_SECRET; the bad-signature
#                and missing-signature cases expect 403.
#   permissive → META_APP_SECRET was not set in the serve environment, so
#                requests go unsigned and the two signature cases report SKIP.
#
# OUTBOUND SENDING: every case below that gets a reply triggers a real send
# through sendWhatsAppMessage() (see index.ts), which calls Meta's Cloud API
# LIVE by default. This suite REFUSES TO RUN unless WHATSAPP_SEND_MODE=mock is
# set in the serving environment — see the preflight check below — so it can
# never fire a real WhatsApp message at the seeded test phone numbers.
#
# PAY / past_due 'in': also REAL Razorpay. Both intents now call
# send-renewal-reminder internally (see requestPaymentLink() in index.ts),
# which creates a real Razorpay TEST MODE payment link — same as
# send-renewal-reminder/test.sh does directly. Nothing is charged; this suite
# refuses to run against an rzp_live_ key, same guard as that suite.
# ---------------------------------------------------------------------------

set -uo pipefail

BASE_URL="${BASE_URL:-http://127.0.0.1:54321/functions/v1/whatsapp-webhook}"
ENV_FILE="${ENV_FILE:-$(dirname "$0")/../.env}"
DB_CONTAINER="${DB_CONTAINER:-supabase_db_gym-saas}"

# Seeded fixtures (see supabase/seed.sql)
PHONE_ACTIVE=919999999999      # Iron Temple only, active membership
PHONE_PAST_DUE=918888888888    # Iron Temple only, past_due membership
PHONE_MULTI=917777777777       # member at BOTH gyms
PHONE_UNKNOWN=916666666666     # not a member anywhere
MEMBER_MULTI_IRON=e3333333-3333-3333-3333-333333333333
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
  # Reads KEY=value from the env file, ignoring comments. Empty if absent.
  [ -f "$ENV_FILE" ] || return 0
  sed -n "s/^[[:space:]]*$1=//p" "$ENV_FILE" | tail -1 | tr -d '\r"'
}

VERIFY_TOKEN="${META_VERIFY_TOKEN:-$(read_env META_VERIFY_TOKEN)}"
APP_SECRET="${META_APP_SECRET:-$(read_env META_APP_SECRET)}"
WA_SEND_MODE="${WHATSAPP_SEND_MODE:-$(read_env WHATSAPP_SEND_MODE)}"
RZP_KEY_ID="${RAZORPAY_KEY_ID:-$(read_env RAZORPAY_KEY_ID)}"

have_psql=false
if docker exec "$DB_CONTAINER" true >/dev/null 2>&1; then have_psql=true; fi

have_openssl=false
if command -v openssl >/dev/null 2>&1; then have_openssl=true; fi

# ---------------------------------------------------------------------------
# Assertions
# ---------------------------------------------------------------------------

ok()      { PASS=$((PASS+1)); printf '  %sPASS%s  %s\n' "$G" "$N" "$1"; }
bad()     { FAIL=$((FAIL+1)); FAILED_CASES+=("$1"); printf '  %sFAIL%s  %s\n' "$R" "$N" "$1"
            printf '        expected: %s\n        actual:   %s\n' "$2" "$3"; }
skipped() { SKIP=$((SKIP+1)); printf '  %sSKIP%s  %s\n           %s\n' "$Y" "$N" "$1" "$2"; }

# assert_contains <label> <expected-substring> <actual>
assert_contains() {
  case "$3" in
    *"$2"*) ok "$1" ;;
    *)      bad "$1" "contains '$2'" "$3" ;;
  esac
}

# assert_equals <label> <expected> <actual>
assert_equals() {
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "$2" "$3"; fi
}

# ---------------------------------------------------------------------------
# Mock Meta transport
# ---------------------------------------------------------------------------

# Meta's real webhook envelope: entry[].changes[].value.messages[]
envelope() { # <from> <wamid> <text>
  printf '{"object":"whatsapp_business_account","entry":[{"id":"WABA_ID","changes":[{"field":"messages","value":{"messaging_product":"whatsapp","metadata":{"display_phone_number":"911111111111","phone_number_id":"PHONE_ID"},"messages":[{"from":"%s","id":"%s","timestamp":"1700000000","type":"text","text":{"body":"%s"}}]}}]}]}' "$1" "$2" "$3"
}

sign() { # <body> -> sha256=<hex>
  printf '%s' "$1" \
    | openssl dgst -sha256 -hmac "$APP_SECRET" \
    | sed 's/^.*= */sha256=/'
}

# post <body> [signature-override] -> response body
# signature-override: "VALID" (default), "NONE", or a literal header value.
post() {
  local body="$1" mode="${2:-VALID}" args=(-s -X POST "$BASE_URL" -H 'Content-Type: application/json')

  if [ "$mode" = "VALID" ]; then
    if [ "$SIG_MODE" = "enforcing" ]; then
      args+=(-H "X-Hub-Signature-256: $(sign "$body")")
    fi
  elif [ "$mode" != "NONE" ]; then
    args+=(-H "X-Hub-Signature-256: $mode")
  fi

  curl "${args[@]}" -d "$body"
}

# post_status <body> [signature-override] -> HTTP status code only
post_status() {
  local body="$1" mode="${2:-VALID}" args=(-s -o /dev/null -w '%{http_code}' -X POST "$BASE_URL" -H 'Content-Type: application/json')

  if [ "$mode" = "VALID" ]; then
    if [ "$SIG_MODE" = "enforcing" ]; then
      args+=(-H "X-Hub-Signature-256: $(sign "$body")")
    fi
  elif [ "$mode" != "NONE" ]; then
    args+=(-H "X-Hub-Signature-256: $mode")
  fi

  curl "${args[@]}" -d "$body"
}

send_message() { post "$(envelope "$1" "$2" "$3")"; }

# ---------------------------------------------------------------------------
# Database helpers (optional — cases degrade to SKIP without docker/psql)
# ---------------------------------------------------------------------------

sql() { docker exec "$DB_CONTAINER" psql -U postgres -d postgres -tAc "$1" 2>/dev/null | tr -d '\r'; }

# Most recent outbound reply body for a phone's member rows.
last_reply() { # <phone>
  sql "select w.body_preview from whatsapp_messages w
       where w.direction='outbound'
         and (w.member_id in (select id from members where phone='$1') or w.member_id is null)
       order by w.created_at desc limit 1;"
}

attendance_count() { # <phone>
  sql "select count(*) from attendance
       where member_id in (select id from members where phone='$1');"
}

reset_state() {
  $have_psql || return 0
  sql "truncate webhook_events, whatsapp_messages, attendance, member_active_context;" >/dev/null
}

# assert_db <label> <expected> <actual>  — SKIPs when psql is unavailable
assert_db() {
  if ! $have_psql; then
    skipped "$1" "docker/psql unavailable (container '$DB_CONTAINER')"
    return
  fi
  assert_equals "$1" "$2" "$3"
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

printf '\n%s== mock-meta webhook tests ==%s\n' "$B" "$N"
printf 'target: %s\n' "$BASE_URL"

if [ "$(printf '%s' "$WA_SEND_MODE" | tr '[:upper:]' '[:lower:]')" != "mock" ]; then
  printf '\n%sREFUSING TO RUN%s WHATSAPP_SEND_MODE is not "mock" in %s (got: %s).\n' \
    "$R" "$N" "$ENV_FILE" "${WA_SEND_MODE:-<unset>}"
  printf '        Every reply this suite triggers calls sendWhatsAppMessage(), which hits\n'
  printf '        the real Meta Cloud API LIVE by default. Set WHATSAPP_SEND_MODE=mock in\n'
  printf '        %s and restart `supabase functions serve` before running this suite,\n' "$ENV_FILE"
  printf '        or it will send real WhatsApp messages to the seeded test phone numbers.\n\n'
  exit 1
fi

if [ -z "$RZP_KEY_ID" ]; then
  printf '\n%sERROR%s no RAZORPAY_KEY_ID found in %s\n' "$R" "$N" "$ENV_FILE"
  printf '        The PAY / past_due-checkin cases call send-renewal-reminder, which returns\n'
  printf '        500 razorpay_not_configured without it.\n\n'
  exit 1
fi
case "$RZP_KEY_ID" in
  rzp_test_*) printf 'razorpay: %s %s(TEST MODE)%s\n' "$RZP_KEY_ID" "$G" "$N" ;;
  rzp_live_*) printf '\n%sREFUSING TO RUN%s RAZORPAY_KEY_ID is a LIVE key (%s).\n' "$R" "$N" "$RZP_KEY_ID"
              printf '        The PAY / past_due-checkin cases create real payment links. Use test-mode keys.\n\n'
              exit 1 ;;
  *)          printf 'razorpay: %s %s(unrecognised key prefix)%s\n' "$RZP_KEY_ID" "$Y" "$N" ;;
esac

if ! curl -s -o /dev/null --max-time 5 "$BASE_URL"; then
  printf '\n%sERROR%s cannot reach the function. Start it with:\n' "$R" "$N"
  printf '  supabase functions serve whatsapp-webhook --env-file supabase/functions/.env\n\n'
  exit 1
fi

if $have_psql; then
  seeded=$(sql "select count(*) from members;")
  if [ "${seeded:-0}" = "0" ]; then
    printf '\n%sERROR%s members table is empty. Run: supabase db reset\n\n' "$R" "$N"
    exit 1
  fi
else
  printf '%swarn%s  docker/psql unavailable — database assertions will SKIP\n' "$Y" "$N"
fi

# Probe signature enforcement with a statuses-only payload: the function acks it
# without writing anything, so the probe has no side effects.
PROBE='{"entry":[{"changes":[{"value":{"statuses":[{"id":"probe","status":"delivered"}]}}]}]}'
SIG_MODE=permissive
if [ "$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE_URL" -H 'Content-Type: application/json' -d "$PROBE")" = "403" ]; then
  SIG_MODE=enforcing
fi
printf 'signature mode: %s%s%s\n' "$B" "$SIG_MODE" "$N"

if [ "$SIG_MODE" = "enforcing" ]; then
  if [ -z "$APP_SECRET" ]; then
    printf '\n%sERROR%s function is enforcing signatures but no META_APP_SECRET found in %s\n\n' "$R" "$N" "$ENV_FILE"
    exit 1
  fi
  if ! $have_openssl; then
    printf '\n%sERROR%s openssl is required to sign requests but was not found on PATH.\n' "$R" "$N"
    printf '        Comment out META_APP_SECRET in %s and restart serve to test unsigned.\n\n' "$ENV_FILE"
    exit 1
  fi
fi

RUN=$$-$(date +%s)   # unique per run: (source, event_id) is UNIQUE in webhook_events
reset_state

# ---------------------------------------------------------------------------
# 1. GET verification handshake
# ---------------------------------------------------------------------------
printf '\n%s-- verification handshake --%s\n' "$B" "$N"

got=$(curl -s "$BASE_URL?hub.mode=subscribe&hub.verify_token=$VERIFY_TOKEN&hub.challenge=CHALLENGE_12345")
assert_equals "GET with valid verify_token echoes hub.challenge" "CHALLENGE_12345" "$got"

got=$(curl -s -o /dev/null -w '%{http_code}' "$BASE_URL?hub.mode=subscribe&hub.verify_token=wrong_token&hub.challenge=CHALLENGE_12345")
assert_equals "GET with wrong verify_token is 403" "403" "$got"

got=$(curl -s -o /dev/null -w '%{http_code}' "$BASE_URL")
assert_equals "GET with no params is 403" "403" "$got"

# ---------------------------------------------------------------------------
# 2. POST signature authentication
# ---------------------------------------------------------------------------
printf '\n%s-- POST signature authentication --%s\n' "$B" "$N"

if [ "$SIG_MODE" = "enforcing" ]; then
  body=$(envelope "$PHONE_ACTIVE" "wamid.$RUN.sig-bad" "in")

  got=$(post_status "$body" "sha256=deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef")
  assert_equals "POST with invalid signature is rejected 403" "403" "$got"

  got=$(post_status "$body" "NONE")
  assert_equals "POST with missing signature header is rejected 403" "403" "$got"

  got=$(post_status "$body" "not-even-prefixed")
  assert_equals "POST with malformed signature header is rejected 403" "403" "$got"

  # A rejected request must not have been processed as valid.
  assert_db "rejected POSTs wrote no webhook_events row" \
    "0" "$(sql "select count(*) from webhook_events where event_id='wamid.$RUN.sig-bad';")"
  assert_db "rejected POSTs created no attendance" \
    "0" "$(attendance_count "$PHONE_ACTIVE")"

  # Positive control: same body, correct signature, is accepted.
  got=$(post_status "$body" "VALID")
  assert_equals "POST with valid signature is accepted 200" "200" "$got"
else
  skipped "POST signature rejection cases" \
    "function is in permissive mode. Set META_APP_SECRET in $ENV_FILE and restart serve."
fi

reset_state

# ---------------------------------------------------------------------------
# 3. Check-in intent
# ---------------------------------------------------------------------------
printf '\n%s-- check-in --%s\n' "$B" "$N"

got=$(send_message "$PHONE_ACTIVE" "wamid.$RUN.a1" "in")
assert_contains "active member 'in' resolves"        '"resolution":"resolved"' "$got"
assert_db       "active member 'in' replies checked-in" "Checked in ✅" "$(last_reply "$PHONE_ACTIVE")"
assert_db       "active member 'in' records attendance" "1" "$(attendance_count "$PHONE_ACTIVE")"

got=$(send_message "$PHONE_PAST_DUE" "wamid.$RUN.a2" "in")
assert_contains "past_due member 'in' resolves"      '"resolution":"resolved"' "$got"
reply=$(last_reply "$PHONE_PAST_DUE")
assert_contains "past_due member 'in' gets a real payment link" \
  "Pay here to continue: https://rzp.io/" "$reply"
assert_contains "past_due member 'in' reply names them"          "Bharat Rao" "$reply"
assert_db       "past_due member 'in' records NO attendance" "0" "$(attendance_count "$PHONE_PAST_DUE")"

printf '\n  %sREAL RAZORPAY LINK CREATED%s (via send-renewal-reminder, PHONE_PAST_DUE):\n    %s\n\n' \
  "$B" "$N" "$reply"

# A second ask the SAME day must not create a second link or re-send the
# message — send-renewal-reminder's own once-per-day guard fires, and
# requestPaymentLink() must turn that into an honest reply, not silence.
got=$(send_message "$PHONE_PAST_DUE" "wamid.$RUN.a2b" "PAY")
assert_contains "repeat 'PAY' the same day resolves"  '"resolution":"resolved"' "$got"
assert_db       "repeat 'PAY' the same day says a link was already sent" \
  "We already sent you a payment link earlier today — check your recent WhatsApp messages, or ask the front desk if you can't find it." \
  "$(last_reply "$PHONE_PAST_DUE")"

# ---------------------------------------------------------------------------
# 4. Tenant resolution
# ---------------------------------------------------------------------------
printf '\n%s-- tenant resolution --%s\n' "$B" "$N"

got=$(send_message "$PHONE_MULTI" "wamid.$RUN.b1" "in")
assert_contains "multi-gym phone with no context is ambiguous" '"resolution":"ambiguous"' "$got"
assert_db       "ambiguous reply lists both gyms" \
  "You're registered at multiple gyms. Reply 1 for Iron Temple Gym, 2 for FlexFit Studio" \
  "$(last_reply "$PHONE_MULTI")"
assert_db       "ambiguous phone records NO attendance" "0" "$(attendance_count "$PHONE_MULTI")"
assert_db       "ambiguous phone gets NO auto-context" \
  "0" "$(sql "select count(*) from member_active_context where phone='$PHONE_MULTI';")"

got=$(send_message "$PHONE_UNKNOWN" "wamid.$RUN.b2" "in")
assert_contains "unknown phone is not_found" '"resolution":"not_found"' "$got"
assert_db       "unknown phone replies front-desk message" \
  "We couldn't find you — check with your gym's front desk" "$(last_reply "$PHONE_UNKNOWN")"

assert_db "single-gym phone got an auto-created context" \
  "1" "$(sql "select count(*) from member_active_context where phone='$PHONE_ACTIVE';")"

# Messy formatting: Meta sends digits, but a copy-pasted/formatted number must
# normalize to the same stored value.
got=$(send_message "+91-99999-99999" "wamid.$RUN.b3" "in")
assert_contains "messy phone format '+91-99999-99999' resolves" '"resolution":"resolved"' "$got"
assert_db       "messy phone format maps to the same member" \
  "2" "$(attendance_count "$PHONE_ACTIVE")"

# ---------------------------------------------------------------------------
# 5. Other intents
# ---------------------------------------------------------------------------
printf '\n%s-- other intents --%s\n' "$B" "$N"

got=$(send_message "$PHONE_ACTIVE" "wamid.$RUN.c1" "PAY")
assert_contains "'PAY' resolves" '"resolution":"resolved"' "$got"
pay_reply=$(last_reply "$PHONE_ACTIVE")
assert_contains "'PAY' from an active member also gets a real payment link" \
  "Pay here to continue: https://rzp.io/" "$pay_reply"

printf '\n  %sREAL RAZORPAY LINK CREATED%s (via send-renewal-reminder, PHONE_ACTIVE / PAY):\n    %s\n\n' \
  "$B" "$N" "$pay_reply"

got=$(send_message "$PHONE_ACTIVE" "wamid.$RUN.c2" "hello there")
assert_contains "gibberish resolves" '"resolution":"resolved"' "$got"
assert_db       "gibberish replies fallback help text" \
  "Sorry, I didn't understand. Reply IN to check in, or PAY to renew your membership." \
  "$(last_reply "$PHONE_ACTIVE")"

# 'switch' from a single-gym member — nothing to switch to.
got=$(send_message "$PHONE_ACTIVE" "wamid.$RUN.c3" "switch")
assert_contains "'switch' from single-gym member resolves" '"resolution":"resolved"' "$got"
assert_db       "'switch' from single-gym member says nothing to switch to" \
  "You're only registered at Iron Temple Gym, so there's nothing to switch to." \
  "$(last_reply "$PHONE_ACTIVE")"

# 'switch' WITHOUT context — resolution short-circuits before intent parsing,
# so the ambiguity prompt wins. This is step (c)-before-(d) by design.
got=$(send_message "$PHONE_MULTI" "wamid.$RUN.c4" "switch")
assert_contains "'switch' without context short-circuits to ambiguous" '"resolution":"ambiguous"' "$got"

# 'switch' WITH context — now the intent is actually reached.
if $have_psql; then
  sql "insert into member_active_context (phone, active_member_id, active_org_id)
       values ('$PHONE_MULTI','$MEMBER_MULTI_IRON','$ORG_IRON')
       on conflict (phone) do nothing;" >/dev/null

  got=$(send_message "$PHONE_MULTI" "wamid.$RUN.c5" "switch")
  assert_contains "'switch' with context resolves" '"resolution":"resolved"' "$got"
  assert_db       "'switch' with context lists both gyms" \
    "You're registered at multiple gyms. Reply 1 for Iron Temple Gym, 2 for FlexFit Studio" \
    "$(last_reply "$PHONE_MULTI")"
else
  skipped "'switch' with active context" "requires psql to pin member_active_context"
fi

# ---------------------------------------------------------------------------
# 6. Idempotency
# ---------------------------------------------------------------------------
printf '\n%s-- idempotency --%s\n' "$B" "$N"

reset_state
dup="wamid.$RUN.dup"

got=$(send_message "$PHONE_ACTIVE" "$dup" "in")
assert_contains "first delivery of event is processed" '"resolution":"resolved"' "$got"
before=$(attendance_count "$PHONE_ACTIVE")

got=$(send_message "$PHONE_ACTIVE" "$dup" "in")
assert_contains "replayed event is skipped as duplicate" '"duplicate":true' "$got"
assert_db       "replayed event creates NO second attendance row" "$before" "$(attendance_count "$PHONE_ACTIVE")"
assert_db       "replayed event stored only once" \
  "1" "$(sql "select count(*) from webhook_events where event_id='$dup';")"

# ---------------------------------------------------------------------------
# 7. Malformed / non-message payloads
# ---------------------------------------------------------------------------
printf '\n%s-- malformed payloads --%s\n' "$B" "$N"

got=$(post "$PROBE")
assert_contains "statuses-only callback is acked without processing" '"ignored":"no_message"' "$got"

got=$(post 'not json at all')
assert_contains "unparseable body is acked, not crashed" '"ignored":"unparseable_body"' "$got"

got=$(curl -s -X DELETE "$BASE_URL")
assert_contains "unsupported method is rejected" 'method_not_allowed' "$got"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
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
