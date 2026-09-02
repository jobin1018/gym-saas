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
OWNER_USER_IRON=91111111-1111-1111-1111-111111111111   # membership_freezes.created_by fixture

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

# assert_not_contains <label> <forbidden-substring> <actual>
assert_not_contains() {
  case "$3" in
    *"$2"*) bad "$1" "does NOT contain '$2'" "$3" ;;
    *)      ok "$1" ;;
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
  sql "truncate webhook_events, whatsapp_messages, attendance, member_active_context, coach_magic_links;" >/dev/null
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
# 8. Owner / coach read-only commands
# ---------------------------------------------------------------------------
printf '\n%s-- owner / coach commands --%s\n' "$B" "$N"

reset_state

# Seeded "Apex Strength Co." fixture (supabase/seed.sql):
#   919100000001  Nisha Raman   owner
#   919100000003  Rhea Kapoor   coach   (clients: Aditya, Carlos, Hannah)
ORG_APEX=a9ec0000-0000-0000-0000-0000000000a1
PHONE_OWNER=919100000001
PHONE_COACH=919100000003
PHONE_OWNER_IRON=919000000001      # Ravi Krishnan, Iron Temple

# last outbound reply body scoped to an org (owner/coach replies have member_id NULL)
last_out_org() { sql "select body_preview from whatsapp_messages
  where direction='outbound' and organization_id='$1' order by created_at desc limit 1;"; }

send_cmd() { send_message "$1" "wamid.$RUN.$2" "$3" >/dev/null; }

if ! $have_psql; then
  skipped "owner/coach command suite" "requires docker/psql for data assertions"
else
  # Apex is seeded status='suspended' (that is the deliberate suspended-org
  # fixture). The owner/coach COMMAND tests below need a live org, so flip it
  # active for their duration; 8i flips it back to 'suspended' and asserts the
  # freeze. Restore-on-exit too, in case an assertion aborts the run.
  sql "update organizations set status='active' where id='$ORG_APEX'" >/dev/null
  trap "sql \"update organizations set status='suspended' where id='$ORG_APEX'\" >/dev/null 2>&1" EXIT

  # a little TODAY-dated activity (reset_state truncated attendance + messages)
  sql "insert into attendance (organization_id, member_id, source) values
        ('$ORG_APEX','a9ec0000-0000-0000-0000-0000000000f1','whatsapp_self'),
        ('$ORG_APEX','a9ec0000-0000-0000-0000-0000000000f3','front_desk'),
        ('$ORG_APEX','a9ec0000-0000-0000-0000-0000000000f8','whatsapp_self');
      insert into whatsapp_messages (organization_id, direction, body_preview, status)
        values ('$ORG_APEX','outbound','seed failed test','failed');" >/dev/null

  # --- 8a. each owner command returns correct data ---
  send_cmd "$PHONE_OWNER" o-rev "REVENUE"
  r=$(last_out_org "$ORG_APEX")
  assert_contains "REVENUE names the org + both sources" "Revenue — Apex Strength Co." "$r"
  assert_contains "REVENUE has the membership line"      "Memberships:" "$r"
  assert_contains "REVENUE has the PT line"              "PT packages:" "$r"
  assert_contains "REVENUE has last-month comparison"    "Last month:" "$r"

  send_cmd "$PHONE_OWNER" o-alr "ALERTS"
  r=$(last_out_org "$ORG_APEX")
  assert_contains "ALERTS summarises overdue"            "Overdue:" "$r"
  assert_contains "ALERTS summarises PT attention"       "PT attention:" "$r"
  assert_contains "ALERTS points to detail commands"     "Text OVERDUE or PT" "$r"

  send_cmd "$PHONE_OWNER" o-tod "TODAY"
  r=$(last_out_org "$ORG_APEX")
  assert_contains "TODAY counts the 3 check-ins"         "Check-ins: 3" "$r"
  assert_contains "TODAY counts the failed send (24h)"   "Failed sends (24h): 1" "$r"
  assert_contains "TODAY has the renewals line"          "Renewals due today:" "$r"
  assert_contains "TODAY has the PT sessions line"       "PT sessions logged:" "$r"

  send_cmd "$PHONE_OWNER" o-ovr "OVERDUE"
  r=$(last_out_org "$ORG_APEX")
  assert_contains "OVERDUE lists the past_due member"    "Ishaan Verma" "$r"
  assert_contains "OVERDUE shows an amount owed"         "1,800" "$r"
  assert_contains "OVERDUE shows days late"              " late" "$r"

  send_cmd "$PHONE_OWNER" o-pt "PT"
  r=$(last_out_org "$ORG_APEX")
  assert_contains "PT shows active package count"        "Active packages:" "$r"
  assert_contains "PT shows this month's PT revenue"     "PT revenue this month:" "$r"
  assert_contains "PT shows the low-sessions list"       "Low on sessions" "$r"
  assert_contains "PT shows the expiring-soon list"      "Expiring soon" "$r"

  send_cmd "$PHONE_OWNER" o-coa "COACHES"
  r=$(last_out_org "$ORG_APEX")
  assert_contains "COACHES lists Rhea as logging"        "Rhea Kapoor" "$r"
  assert_contains "COACHES flags an active logger"       "logging ✅" "$r"
  assert_contains "COACHES flags a quiet coach (Sam, 26d)" "quiet ⚠️" "$r"

  send_cmd "$PHONE_OWNER" o-lap "LAPSED"
  r=$(last_out_org "$ORG_APEX")
  assert_contains "LAPSED highlights the total + window" "haven't checked in for 14+ days" "$r"

  send_cmd "$PHONE_OWNER" o-new "NEW"
  r=$(last_out_org "$ORG_APEX")
  assert_contains "NEW shows this vs last month"         "This month: 12" "$r"
  assert_contains "NEW lists a joiner with their plan"   "Aditya Rao" "$r"
  assert_contains "NEW caps the list at 10 with +N more" "+2 more" "$r"

  # --- 8b. HELP + unknown-owner-command fallback (owner-tailored) ---
  # Text content per the reformat spec — grouped, bold-anchored, blank line
  # between groups, no org name (a shared reference card now, not a per-org
  # header). Checked group-by-group and line-by-line rather than as one huge
  # multi-line literal, so a single wrong line points straight at itself.
  send_cmd "$PHONE_OWNER" o-hlp "zzznotacommand"
  r=$(last_out_org "$ORG_APEX")
  assert_contains "unknown owner command falls back to owner HELP" "*Here's what you can ask me* 📋" "$r"

  assert_contains "owner HELP has the Money heading"     $'\n*Money*\n' "$r"
  assert_contains "owner HELP lists REVENUE"             "*REVENUE* — this month's income" "$r"
  assert_contains "owner HELP lists OVERDUE"             "*OVERDUE* — who hasn't paid" "$r"

  assert_contains "owner HELP has the Your Business heading" $'\n*Your Business*\n' "$r"
  assert_contains "owner HELP lists ALERTS"              "*ALERTS* — everything that needs attention right now" "$r"
  assert_contains "owner HELP lists TODAY"               "*TODAY* — check-ins, payments, joins since midnight" "$r"
  assert_contains "owner HELP lists NEW"                 "*NEW* — who joined this week" "$r"
  assert_contains "owner HELP lists LAPSED"              "*LAPSED* — members who've drifted away" "$r"

  assert_contains "owner HELP has the Team heading"      $'\n*Team*\n' "$r"
  assert_contains "owner HELP lists COACHES"             "*COACHES* — who's active, who's gone quiet" "$r"
  assert_contains "owner HELP lists PT"                  "*PT* — packages running low or expiring" "$r"

  assert_contains "owner HELP closes with the footer"    "Just text the word — no need for anything else." "$r"
  assert_contains "owner HELP is Gymdean-branded"        "Powered by Gymdean" "$r"

  # Blank-line grouping and heading→first-command adjacency, spot-checked
  # rather than re-deriving the whole literal.
  assert_contains "Money's REVENUE line follows immediately" $'*Money*\n*REVENUE*' "$r"
  assert_contains "Team's COACHES line follows immediately"  $'*Team*\n*COACHES*' "$r"

  case "$r" in
    *"Reply IN to check in"*) bad "owner HELP must not show member help text" "no member copy" "$r" ;;
    *) ok "owner HELP does not leak member-facing copy" ;;
  esac
  case "$r" in
    *"Commands — Apex Strength Co."*) bad "owner HELP dropped the old per-org header" "no org-name header" "$r" ;;
    *) ok "owner HELP no longer shows the old per-org header" ;;
  esac
  case "$r" in
    *"SESSION"*) bad "owner HELP must not mention the coach-only SESSION command" "no SESSION" "$r" ;;
    *) ok "owner HELP does not mention SESSION (coach-only, not owner-facing)" ;;
  esac

  # --- 8b'. co-owners: a second users role='owner' at the same gym (own
  #          phone, NOT organizations.owner_phone) gets identical command
  #          access. PHONE_OWNER also matches a users row, so this proves the
  #          combined (owner_phone OR users role='owner') check + no regression.
  PHONE_COOWNER=919100000009        # Priya Balan, Apex co-owner (seed.sql)
  send_cmd "$PHONE_OWNER"   co-a "REVENUE"; r_primary=$(last_out_org "$ORG_APEX")
  send_cmd "$PHONE_COOWNER" co-b "REVENUE"; r_coowner=$(last_out_org "$ORG_APEX")
  assert_contains "primary owner (matches owner_phone) gets the Apex REVENUE report" "Revenue — Apex Strength Co." "$r_primary"
  assert_contains "co-owner (matches only a users role='owner' row) also gets it"    "Revenue — Apex Strength Co." "$r_coowner"
  assert_equals   "both co-owners see byte-identical data" "$r_primary" "$r_coowner"
  send_cmd "$PHONE_COOWNER" co-c "zzznope"
  assert_contains "co-owner unknown command -> owner HELP (routed as owner, not not_found)" \
    "*Here's what you can ask me* 📋" "$(last_out_org "$ORG_APEX")"

  # --- 8c. coach path ---
  send_cmd "$PHONE_COACH" c-my "MYCLIENTS"
  r=$(last_out_org "$ORG_APEX")
  assert_contains "MYCLIENTS returns the coach's own list"  "Your clients (3)" "$r"
  assert_contains "MYCLIENTS shows a client name + goal"    "Aditya Rao — Muscle gain" "$r"
  assert_contains "MYCLIENTS shows sessions used/purchased" "sessions" "$r"
  assert_not_contains "MYCLIENTS never leaks Sam's client"  "Ethan Wright" "$r"
  assert_not_contains "MYCLIENTS never leaks Lena's client" "Ishaan Verma" "$r"

  # SESSION / LOG -> a one-time magic link into the quick-log page. The reply
  # is the generation audit; validate-magic-link/test.sh covers redemption.
  send_cmd "$PHONE_COACH" c-ses "SESSION"
  r=$(last_out_org "$ORG_APEX")
  assert_contains "SESSION replies with a /coach/quick-log link" "/coach/quick-log?token=" "$r"
  assert_contains "SESSION link says one use / 15 min"           "one use" "$r"
  RHEA_ID=$(sql "select id from users where phone='$PHONE_COACH' and organization_id='$ORG_APEX'")
  link_row=$(sql "select (used_at is null)||'|'||(expires_at > now())::text||'|'||coach_user_id
                  from coach_magic_links where coach_user_id='$RHEA_ID' order by created_at desc limit 1")
  assert_equals "  ...persisted a fresh coach_magic_links row for this coach" "true|true|$RHEA_ID" "$link_row"
  assert_equals "  ...expiry is ~15 min out (13-15 min)" "t" \
    "$(sql "select (expires_at between now() + interval '13 minutes' and now() + interval '15 minutes')
            from coach_magic_links where coach_user_id='$RHEA_ID' order by created_at desc limit 1")"
  send_cmd "$PHONE_COACH" c-log "LOG"
  assert_contains "LOG is an alias for SESSION" "/coach/quick-log?token=" "$(last_out_org "$ORG_APEX")"

  send_cmd "$PHONE_COACH" c-rev "REVENUE"
  r=$(last_out_org "$ORG_APEX")
  assert_contains "a coach texting an owner command gets coach help" "reply MYCLIENTS" "$r"
  assert_contains "coach help mentions SESSION / LOG"               "SESSION (alias: LOG)" "$r"
  assert_contains "coach help says owner reports are owner-only"     "owner-only" "$r"
  case "$r" in
    *"Revenue —"*) bad "coach must not receive the owner REVENUE report" "coach help" "$r" ;;
    *) ok "coach does not receive owner REVENUE data" ;;
  esac

  # --- 8d. cross-org isolation: an owner only ever sees their own org ---
  send_cmd "$PHONE_OWNER_IRON" x-rev "REVENUE"
  r=$(last_out_org "$ORG_IRON")
  assert_contains "Iron owner's REVENUE names Iron Temple"  "Iron Temple Gym" "$r"
  assert_not_contains "Iron owner's REVENUE never shows Apex" "Apex Strength Co." "$r"
  send_cmd "$PHONE_OWNER_IRON" x-ovr "OVERDUE"
  r=$(last_out_org "$ORG_IRON")
  assert_not_contains "Iron owner's OVERDUE never shows an Apex member" "Ishaan Verma" "$r"
  send_cmd "$PHONE_OWNER_IRON" x-coa "COACHES"
  r=$(last_out_org "$ORG_IRON")
  assert_not_contains "Iron owner's COACHES never shows an Apex coach" "Sam Okafor" "$r"

  # --- 8e. a phone that is not an owner / coach / member ---
  got=$(send_message 919333000777 "wamid.$RUN.nf" "REVENUE")
  assert_contains "unknown phone gets a clean not_found (not an error)" '"resolution":"not_found"' "$got"
  assert_contains "unknown phone response is still ok:true"             '"ok":true' "$got"

  # Throwaway-org fixtures for 8f/8g. status='active': as of the org-status
  # enforcement work (20260902090000) resolveSender() drops suspended orgs
  # entirely, so an ambiguity / owner-command fixture MUST be active to be
  # seen at all. Teardown DELETEs them (heredoc, statement-per-statement,
  # continues past errors) and is also run defensively at the next run's
  # start, so a leak into daily-owner-brief's "4 briefable orgs" invariant
  # only survives an outright teardown failure.
  BULK_ORG=0daded00-0000-0000-0000-0000000b0001
  TWIN_ORG=0daded00-0000-0000-0000-00000000abba
  bulk_teardown() {
    docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -q >/dev/null 2>&1 <<SQL
DELETE FROM whatsapp_messages WHERE organization_id IN ('$BULK_ORG', '$TWIN_ORG');
DELETE FROM memberships      WHERE organization_id = '$BULK_ORG';
DELETE FROM members          WHERE organization_id = '$BULK_ORG';
DELETE FROM membership_plans  WHERE organization_id = '$BULK_ORG';
DELETE FROM locations         WHERE organization_id = '$BULK_ORG';
DELETE FROM organizations     WHERE id = '$BULK_ORG';
DELETE FROM organizations     WHERE id = '$TWIN_ORG';
SQL
  }
  bulk_teardown   # defensive: clear any leak from a previously aborted run

  # --- 8f. multi-org owner_phone collision -> graceful disambiguation ---
  docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -q >/dev/null 2>&1 <<SQL
INSERT INTO organizations (id, name, owner_phone, status)
VALUES ('$TWIN_ORG', 'Twin Peaks Gym', '$PHONE_OWNER_IRON', 'active');
SQL
  send_cmd "$PHONE_OWNER_IRON" amb "REVENUE"
  r=$(sql "select body_preview from whatsapp_messages where direction='outbound' and organization_id is null order by created_at desc limit 1;")
  assert_contains "multi-org owner_phone is flagged, not guessed" "more than one gym" "$r"
  assert_contains "the ambiguous reply names both orgs"           "Twin Peaks Gym" "$r"

  # --- 8g. a genuinely long list is capped + summarised, not malformed ---
  docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -q >/dev/null 2>&1 <<SQL
INSERT INTO organizations (id, name, owner_phone, status)
VALUES ('$BULK_ORG', 'Bulk Test Gym', '919555000111', 'active');
INSERT INTO locations (id, organization_id, name)
VALUES ('0daded00-0000-0000-0000-0000000b0000', '$BULK_ORG', 'Bulk HQ');
INSERT INTO membership_plans (id, organization_id, name, amount)
VALUES ('0daded00-0000-0000-0000-0000000b0002', '$BULK_ORG', 'Bulk Plan', 1000);
DO \$\$
BEGIN
  FOR i IN 1..15 LOOP
    INSERT INTO members (id, organization_id, location_id, name, phone)
    VALUES (('0daded00-0000-0000-0000-0000000c00' || lpad(i::text, 2, '0'))::uuid,
            '$BULK_ORG', '0daded00-0000-0000-0000-0000000b0000',
            'Bulk Member ' || i, '9195551' || lpad(i::text, 5, '0'));
    INSERT INTO memberships (id, organization_id, member_id, plan_id, status, start_date, current_period_end, duration_months)
    VALUES (('0daded00-0000-0000-0000-0000000d00' || lpad(i::text, 2, '0'))::uuid,
            '$BULK_ORG', ('0daded00-0000-0000-0000-0000000c00' || lpad(i::text, 2, '0'))::uuid,
            '0daded00-0000-0000-0000-0000000b0002', 'past_due',
            CURRENT_DATE - 40, CURRENT_DATE - 10, 1);
  END LOOP;
END \$\$;
SQL

  send_cmd 919555000111 bulk-ovr "OVERDUE"
  r=$(last_out_org "$BULK_ORG")
  assert_contains "long OVERDUE shows the true total"    "(15 total)" "$r"
  assert_contains "long OVERDUE caps at 10 + summarises" "+5 more" "$r"
  if [ "${#r}" -lt 3500 ]; then ok "long OVERDUE reply stays a sane length (${#r} bytes)"
  else bad "long OVERDUE reply length" "< 3500 bytes" "${#r} bytes"; fi

  send_cmd 919555000111 bulk-lap "LAPSED"
  r=$(last_out_org "$BULK_ORG")
  assert_contains "long LAPSED caps at 10 + summarises"  "+5 more" "$r"
  if [ "${#r}" -lt 3500 ]; then ok "long LAPSED reply stays a sane length (${#r} bytes)"
  else bad "long LAPSED reply length" "< 3500 bytes" "${#r} bytes"; fi

  bulk_teardown

  # --- 8i. suspended org — owner/coach commands AND member check-ins freeze ---
  #     (org-status enforcement 20260902090000). Apex goes back to its seeded
  #     'suspended' state here; the EXIT trap is only a fallback.
  reset_state
  sql "update organizations set status='suspended' where id='$ORG_APEX'" >/dev/null
  APEX_MEMBER_PHONE=$(sql "select phone from members where organization_id='$ORG_APEX' limit 1;")

  got=$(send_message "$PHONE_OWNER" "wamid.$RUN.susp-o" "REVENUE")
  assert_contains "suspended org: owner REVENUE -> org_suspended resolution" '"resolution":"org_suspended"' "$got"
  assert_contains "  ...owner gets the 'account inactive' reply"  "currently inactive" "$(last_out_org "$ORG_APEX")"
  got=$(send_message "$PHONE_COACH" "wamid.$RUN.susp-c" "MYCLIENTS")
  assert_contains "suspended org: coach MYCLIENTS -> org_suspended resolution" '"resolution":"org_suspended"' "$got"
  got=$(send_message "$PHONE_COACH" "wamid.$RUN.susp-s" "SESSION")
  assert_contains "suspended org: coach SESSION mints no magic link" '"resolution":"org_suspended"' "$got"
  assert_equals   "  ...no coach_magic_links row was created" "0" \
    "$(sql "select count(*) from coach_magic_links cml join users u on u.id=cml.coach_user_id where u.organization_id='$ORG_APEX';")"

  if [ -n "$APEX_MEMBER_PHONE" ]; then
    got=$(send_message "$APEX_MEMBER_PHONE" "wamid.$RUN.susp-m" "in")
    assert_contains "suspended org: member check-in -> clean inactive reply" "currently inactive" "$(last_out_org "$ORG_APEX")"
    assert_equals   "  ...no attendance row written" "0" "$(attendance_count "$APEX_MEMBER_PHONE")"
  fi

  # --- 8h. existing member intents are completely unaffected ---
  reset_state
  got=$(send_message "$PHONE_ACTIVE" "wamid.$RUN.mem-in" "in")
  assert_contains "member IN still resolves + checks in" '"resolution":"resolved"' "$got"
  assert_db       "member IN still writes an attendance row" "1" "$(attendance_count "$PHONE_ACTIVE")"

  trap - EXIT   # 8i already restored Apex to 'suspended'
fi

# ---------------------------------------------------------------------------
# 9. Frozen membership check-in
# ---------------------------------------------------------------------------
# See 20260904090000_membership_freezing.sql. A frozen member's 'in' must get
# a clear "paused until" reply, not fall through to the generic active/expired
# branches, and must record NO attendance. Reuses PHONE_ACTIVE's real
# membership — frozen for the duration of this section only, restored to
# 'active' (its seeded state) immediately after.
printf '\n%s-- frozen membership check-in --%s\n' "$B" "$N"

if ! $have_psql; then
  skipped "frozen member 'in' gets a clear paused reply" "requires docker/psql"
else
  reset_state
  ACTIVE_MEMBERSHIP=$(sql "select ms.id from memberships ms join members m on m.id=ms.member_id
                            where m.phone='$PHONE_ACTIVE' limit 1;")
  FROZEN_UNTIL=$(sql "select (CURRENT_DATE + 12)::text;")
  # fmtDay() in index.ts formats via Intl en-GB { day: numeric, month: short }.
  # On this Deno runtime's ICU data that renders "Sept", not "Sep" — matched
  # here rather than assumed, since GNU date's %b would say "Sep".
  FROZEN_UNTIL_LABEL=$(date -d "$FROZEN_UNTIL" '+%-d %b' 2>/dev/null || date -j -f '%Y-%m-%d' "$FROZEN_UNTIL" '+%-d %b')
  FROZEN_UNTIL_LABEL=$(printf '%s' "$FROZEN_UNTIL_LABEL" | sed 's/Sep$/Sept/')

  sql "update memberships set status='frozen' where id='$ACTIVE_MEMBERSHIP';" >/dev/null
  sql "insert into membership_freezes
         (organization_id, membership_id, frozen_from, frozen_until, days, reason, created_by)
       values ('$ORG_IRON', '$ACTIVE_MEMBERSHIP', CURRENT_DATE - 3, CURRENT_DATE + 12, 15,
               'test fixture', '$OWNER_USER_IRON');" >/dev/null

  got=$(send_message "$PHONE_ACTIVE" "wamid.$RUN.frozen-in" "in")
  assert_contains "frozen member 'in' resolves" '"resolution":"resolved"' "$got"
  assert_contains "frozen member 'in' reply names the paused-until date" \
    "currently paused until $FROZEN_UNTIL_LABEL" "$(last_reply "$PHONE_ACTIVE")"
  assert_db "frozen member 'in' records NO attendance" "0" "$(attendance_count "$PHONE_ACTIVE")"

  # Restore — later re-runs of this suite, and any human poking at seed data
  # afterwards, must find PHONE_ACTIVE active again.
  sql "delete from membership_freezes where membership_id='$ACTIVE_MEMBERSHIP';" >/dev/null
  sql "update memberships set status='active' where id='$ACTIVE_MEMBERSHIP';" >/dev/null
fi

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
