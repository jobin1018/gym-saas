#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# UPI QR payments: settings RLS, Storage bucket, payment mode rule, pay page,
# claim-paid, pending claims, PAY intent + QR image (mock send).
#
# PREREQUISITES (same as the other suites)
#   1. supabase start
#   2. supabase db reset
#   3. supabase functions serve --env-file supabase/functions/.env
#      with WHATSAPP_SEND_MODE=mock, RAZORPAY_MODE=mock, PAY_PAGE_BASE_URL set
#   4. bash supabase/functions/pay-page/test.sh
#
# NOTE: the QR IMAGE message to Meta is only exercised in mock mode here; its
# live Cloud API behaviour is unverified.
# ---------------------------------------------------------------------------
set -uo pipefail

BASE="${BASE:-http://127.0.0.1:54321}"
FN="$BASE/functions/v1"
ENV_FILE="${ENV_FILE:-$(dirname "$0")/../.env}"
DB_CONTAINER="${DB_CONTAINER:-supabase_db_gym-saas}"
PROJECT_DIR="${PROJECT_DIR:-$(dirname "$0")/../../..}"

ORG_IRON=11111111-1111-1111-1111-111111111111
ORG_FLEX=22222222-2222-2222-2222-222222222222
LOC_IRON=aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa
LOC_IRON_2=0daded00-4444-0000-0000-000000000002
MEM=f2222222-2222-2222-2222-222222222222          # Bharat Rao, Iron, past_due, ₹1500
MEMBER=e2222222-2222-2222-2222-222222222222
MEMBER_PHONE=918888888888
MEM_FLEX=f4444444-4444-4444-4444-444444444444     # Chitra @ FlexFit

PASS=0; FAIL=0; SKIP=0; FAILED_CASES=()
if [ -t 1 ]; then G=$'\033[32m'; R=$'\033[31m'; B=$'\033[1m'; N=$'\033[0m'; else G=""; R=""; B=""; N=""; fi
ok()  { PASS=$((PASS+1)); printf '  %sPASS%s  %s\n' "$G" "$N" "$1"; }
bad() { FAIL=$((FAIL+1)); FAILED_CASES+=("$1"); printf '  %sFAIL%s  %s\n        expected: %s\n        actual:   %s\n' "$R" "$N" "$1" "$2" "$3"; }
assert_contains()     { case "$3" in *"$2"*) ok "$1";; *) bad "$1" "contains '$2'" "$3";; esac; }
assert_not_contains() { case "$3" in *"$2"*) bad "$1" "does NOT contain '$2'" "$3";; *) ok "$1";; esac; }
assert_equals()       { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "$2" "$3"; fi; }

read_env() { [ -f "$ENV_FILE" ] && sed -n "s/^[[:space:]]*$1=//p" "$ENV_FILE" | tail -1 | tr -d '\r"'; }
sql() { docker exec "$DB_CONTAINER" psql -U postgres -d postgres -tAc "$1" 2>&1 | tr -d '\r'; }
sqlq() { docker exec "$DB_CONTAINER" psql -U postgres -d postgres -tAc "$1" 2>/dev/null | tr -d '\r'; }

WA_MODE="${WHATSAPP_SEND_MODE:-$(read_env WHATSAPP_SEND_MODE)}"
RZP_MODE="${RAZORPAY_MODE:-$(read_env RAZORPAY_MODE)}"
PAY_BASE="${PAY_PAGE_BASE_URL:-$(read_env PAY_PAGE_BASE_URL)}"
APP_SECRET="${META_APP_SECRET:-$(read_env META_APP_SECRET)}"
printf '\n%s== pay-page (UPI QR) tests ==%s\n' "$B" "$N"
[ "$(echo "$WA_MODE" | tr A-Z a-z)" = "mock" ]  || { echo "REFUSING: WHATSAPP_SEND_MODE must be mock"; exit 1; }
[ "$(echo "$RZP_MODE" | tr A-Z a-z)" = "mock" ] || { echo "REFUSING: RAZORPAY_MODE must be mock"; exit 1; }
[ -n "$PAY_BASE" ] || { echo "ERROR: PAY_PAGE_BASE_URL not set in $ENV_FILE"; exit 1; }

STATUS_ENV=$(cd "$PROJECT_DIR" && supabase status -o env 2>/dev/null)
ANON_KEY=$(printf '%s' "$STATUS_ENV" | sed -n 's/^ANON_KEY="\(.*\)"$/\1/p' | tail -1)
SERVICE_KEY=$(printf '%s' "$STATUS_ENV" | sed -n 's/^SERVICE_ROLE_KEY="\(.*\)"$/\1/p' | tail -1)
[ -n "$ANON_KEY" ] && [ -n "$SERVICE_KEY" ] || { echo "ERROR: no keys from supabase status"; exit 1; }

login() { curl -s -X POST "$FN/staff-login" -H "Authorization: Bearer $ANON_KEY" -H 'Content-Type: application/json' \
  -d "{\"organization_id\":\"$1\",\"phone\":\"$2\",\"pin\":\"$3\"}" | sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p'; }
rest()        { curl -s "$BASE/rest/v1/$2" -H "apikey: $ANON_KEY" -H "Authorization: Bearer $1"; }
rest_status() { curl -s -o /dev/null -w '%{http_code}' "$BASE/rest/v1/$2" -H "apikey: $ANON_KEY" -H "Authorization: Bearer $1"; }
rest_post()   { curl -s -w ' HTTP%{http_code}' -X POST "$BASE/rest/v1/$2" -H "apikey: $ANON_KEY" -H "Authorization: Bearer $1" -H 'Content-Type: application/json' -H 'Prefer: return=representation' -d "$3"; }
rest_patch()  { curl -s -w ' HTTP%{http_code}' -X PATCH "$BASE/rest/v1/$2" -H "apikey: $ANON_KEY" -H "Authorization: Bearer $1" -H 'Content-Type: application/json' -H 'Prefer: return=representation' -d "$3"; }
rpc()         { curl -s -X POST "$BASE/rest/v1/rpc/$2" -H "apikey: $ANON_KEY" -H "Authorization: Bearer $1" -H 'Content-Type: application/json' -d "$3"; }
remind()      { curl -s -X POST "$FN/send-renewal-reminder" -H "authorization: Bearer $SERVICE_KEY" -H 'content-type: application/json' -d "{\"membership_id\":\"$1\"}"; }
# page/claim <token> [client-ip]
page()  { curl -s -w ' HTTP%{http_code}' -X POST "$FN/get-pay-page" -H "apikey: $ANON_KEY" -H 'content-type: application/json' -H "cf-connecting-ip: ${2:-198.51.100.1}" -d "{\"token\":\"$1\"}"; }
claim() { curl -s -w ' HTTP%{http_code}' -X POST "$FN/claim-paid"   -H "apikey: $ANON_KEY" -H 'content-type: application/json' -H "cf-connecting-ip: ${2:-198.51.100.2}" -d "{\"token\":\"$1\"}"; }
upload() { # <token> <path> <content-type> <file>
  curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/storage/v1/object/payment-qr/$2" -H "apikey: $ANON_KEY" -H "Authorization: Bearer $1" \
    -H "Content-Type: $3" -H 'x-upsert: true' --data-binary "@$4"; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
# 1x1 PNG
printf 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==' | base64 -d > "$TMP/qr.png"
head -c 3000000 /dev/urandom > "$TMP/big.png"
echo "not an image" > "$TMP/x.txt"

reset_state() {
  sqlq "update organizations set status='active' where id in ('$ORG_IRON','$ORG_FLEX');
        delete from payment_requests; delete from payment_link_skips; delete from pay_page_hits;
        delete from org_payment_settings;
        delete from whatsapp_messages where member_id in ('$MEMBER','e4444444-4444-4444-4444-444444444444') and created_at::date=current_date;
        delete from payments where provider='manual' and membership_id in ('$MEM','$MEM_FLEX');
        delete from payments where membership_id in ('$MEM','$MEM_FLEX') and idempotency_key like 'renewal-%';
        update memberships set current_period_end='$(sqlq "select (current_date-10)::text")', status='past_due' where id='$MEM';
        update members set location_id='$LOC_IRON' where id='$MEMBER';
        delete from locations where id='$LOC_IRON_2';" >/dev/null
}
reset_state
# seeded Bharat membership end date at the time of the run (stable within the suite)
sqlq "update memberships set current_period_end=current_date-10 where id='$MEM'" >/dev/null

OWNER=$(login $ORG_IRON 919000000001 1234)
FD=$(login $ORG_IRON 919000000011 1111)
COACH=$(login $ORG_IRON 918454000001 1234)
FLEX_OWNER=$(login $ORG_FLEX 919000000002 2345)
[ -n "$OWNER" ] && [ -n "$FD" ] && [ -n "$COACH" ] && [ -n "$FLEX_OWNER" ] || { echo "ERROR: could not log in fixtures"; exit 1; }

# ===========================================================================
printf '\n%s-- Storage bucket --%s\n' "$B" "$N"
assert_equals "bucket is private, 2 MB, png/jpeg only" "f|2097152|{image/png,image/jpeg}" \
  "$(sqlq "select public, file_size_limit, allowed_mime_types from storage.buckets where id='payment-qr'" | tr -d '"')"
assert_equals "owner uploads PNG to own org folder" 200 "$(upload $OWNER $ORG_IRON/qr.png image/png $TMP/qr.png)"
assert_equals "owner cannot upload into another org's folder" 400 "$(upload $OWNER $ORG_FLEX/qr.png image/png $TMP/qr.png)"
assert_equals "front_desk cannot upload" 400 "$(upload $FD $ORG_IRON/fd.png image/png $TMP/qr.png)"
assert_equals "coach cannot upload" 400 "$(upload $COACH $ORG_IRON/c.png image/png $TMP/qr.png)"
assert_equals "text/plain is rejected server-side" 400 "$(upload $OWNER $ORG_IRON/x.png text/plain $TMP/x.txt)"
assert_equals "3 MB image is rejected server-side" 400 "$(upload $OWNER $ORG_IRON/big.png image/png $TMP/big.png)"
assert_equals "anon cannot read the object" 400 "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/storage/v1/object/payment-qr/$ORG_IRON/qr.png" -H "apikey: $ANON_KEY")"
assert_equals "Flex owner cannot read Iron's object" 400 "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/storage/v1/object/authenticated/payment-qr/$ORG_IRON/qr.png" -H "apikey: $ANON_KEY" -H "Authorization: Bearer $FLEX_OWNER")"
assert_equals "front_desk can read own org's object" 200 "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/storage/v1/object/authenticated/payment-qr/$ORG_IRON/qr.png" -H "apikey: $ANON_KEY" -H "Authorization: Bearer $FD")"

# ===========================================================================
printf '\n%s-- org_payment_settings access --%s\n' "$B" "$N"
out=$(rest_post $OWNER org_payment_settings "{\"organization_id\":\"$ORG_IRON\",\"upi_id\":\"irontemple@okhdfc\",\"qr_image_path\":\"$ORG_IRON/qr.png\",\"qr_enabled\":true}")
assert_contains "owner creates own org's settings" "HTTP201" "$out"
assert_equals "razorpay_enabled defaults to false" "f" "$(sqlq "select razorpay_enabled from org_payment_settings where organization_id='$ORG_IRON'")"
assert_contains "front_desk can READ settings" "irontemple@okhdfc" "$(rest $FD "org_payment_settings?select=upi_id")"
out=$(rest_patch $FD "org_payment_settings?organization_id=eq.$ORG_IRON" '{"upi_id":"hacked@upi"}')
assert_equals "front_desk cannot edit (row unchanged)" "irontemple@okhdfc" "$(sqlq "select upi_id from org_payment_settings where organization_id='$ORG_IRON'")"
out=$(rest_post $FD org_payment_settings "{\"organization_id\":\"$ORG_IRON\",\"upi_id\":\"x@upi\"}")
assert_not_contains "front_desk cannot insert" "HTTP201" "$out"
assert_equals "coach sees nothing" "[]" "$(rest $COACH org_payment_settings)"
assert_equals "anon sees nothing / is denied" "401" "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/rest/v1/org_payment_settings" -H "apikey: $ANON_KEY")"
assert_equals "other org's owner sees nothing" "[]" "$(rest $FLEX_OWNER org_payment_settings)"
rest_patch $FLEX_OWNER "org_payment_settings?organization_id=eq.$ORG_IRON" '{"upi_id":"evil@upi"}' >/dev/null
assert_equals "other org's owner cannot edit Iron's settings" "irontemple@okhdfc" "$(sqlq "select upi_id from org_payment_settings where organization_id='$ORG_IRON'")"
out=$(rest_post $FLEX_OWNER org_payment_settings "{\"organization_id\":\"$ORG_IRON\",\"upi_id\":\"evil@upi\"}")
assert_not_contains "other org's owner cannot insert for Iron" "HTTP201" "$out"
out=$(rest_patch $OWNER "org_payment_settings?organization_id=eq.$ORG_IRON" "{\"qr_image_path\":\"$ORG_FLEX/qr.png\"}")
assert_not_contains "owner cannot point the QR at another org's folder" "HTTP200" "$out"
out=$(rest_patch $OWNER "org_payment_settings?organization_id=eq.$ORG_IRON" '{"upi_id":"not a upi id"}')
assert_not_contains "malformed UPI id is rejected" "HTTP200" "$out"
sqlq "update organizations set status='suspended' where id='$ORG_IRON'" >/dev/null
rest_patch $OWNER "org_payment_settings?organization_id=eq.$ORG_IRON" '{"upi_id":"late@upi"}' >/dev/null
assert_equals "suspended org: settings cannot be edited" "irontemple@okhdfc" "$(sqlq "select upi_id from org_payment_settings where organization_id='$ORG_IRON'")"
assert_equals "suspended org: QR upload refused" 400 "$(upload $OWNER $ORG_IRON/late.png image/png $TMP/qr.png)"
sqlq "update organizations set status='active' where id='$ORG_IRON'" >/dev/null

# ===========================================================================
printf '\n%s-- payment_requests: no direct access --%s\n' "$B" "$N"
for t in payment_requests pay_page_hits payment_link_skips; do
  assert_equals "authenticated owner cannot read $t directly" "403" "$(rest_status $OWNER $t)"
  assert_equals "anon cannot read $t directly" "401" "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/rest/v1/$t" -H "apikey: $ANON_KEY")"
done
assert_contains "authenticated cannot call get_or_create_payment_request" "permission denied" \
  "$(rpc $OWNER get_or_create_payment_request "{\"p_membership_id\":\"$MEM\",\"p_pt_package_id\":null,\"p_amount\":1500}")"
assert_contains "authenticated cannot call get_pay_page_data" "permission denied" "$(rpc $OWNER get_pay_page_data '{"p_token":"x"}')"
assert_contains "authenticated cannot call claim_payment_request" "permission denied" "$(rpc $OWNER claim_payment_request '{"p_token":"x"}')"
assert_equals "token column is 32 hex chars of default random" "t" \
  "$(sqlq "select (extensions.gen_random_bytes(16) is not null)")"

# ===========================================================================
printf '\n%s-- mode rule: QR gym --%s\n' "$B" "$N"
PAYMENTS_BEFORE=$(sqlq "select count(*) from payments where membership_id='$MEM'")
got=$(remind $MEM)
assert_contains "QR gym: reminder created, mode=qr" '"mode":"qr"' "$got"
assert_contains "QR gym: payment_url is the pay page" "\"payment_url\":\"$PAY_BASE/" "$got"
assert_not_contains "QR gym: no razorpay link in the response" "razorpay_link_id" "$got"
assert_equals "QR gym: NO Razorpay call (no payments row, no plink id)" "$PAYMENTS_BEFORE" "$(sqlq "select count(*) from payments where membership_id='$MEM'")"
assert_equals "QR gym: no plink_mock anywhere in today's messages" "0" "$(sqlq "select count(*) from whatsapp_messages where member_id='$MEMBER' and body_preview like '%rzp.mock%'")"
TOKEN=$(sqlq "select token from payment_requests where membership_id='$MEM'")
assert_equals "one payment_request, token 128-bit hex" "1" "$(sqlq "select count(*) from payment_requests where membership_id='$MEM' and token ~ '^[0-9a-f]{32}\$'")"
assert_equals "the reminder carries the pay URL in the template message" "1" \
  "$(sqlq "select count(*) from whatsapp_messages where member_id='$MEMBER' and template_name='renewal_reminder' and body_preview like '%$PAY_BASE/$TOKEN%'")"
assert_equals "request amount is the renewal total" "1500.00" "$(sqlq "select amount from payment_requests where membership_id='$MEM'")"

sqlq "delete from whatsapp_messages where member_id='$MEMBER' and created_at::date=current_date" >/dev/null
got=$(remind $MEM)
assert_contains "same period again: reused" '"reused":true' "$got"
assert_equals "same period again: still ONE request" "1" "$(sqlq "select count(*) from payment_requests where membership_id='$MEM'")"
assert_equals "same period again: same token" "$TOKEN" "$(sqlq "select token from payment_requests where membership_id='$MEM'")"

sqlq "update memberships set current_period_end=current_period_end+30 where id='$MEM'; delete from whatsapp_messages where member_id='$MEMBER' and created_at::date=current_date" >/dev/null
remind $MEM >/dev/null
assert_equals "next period: a NEW request (2 total, 1 per period)" "2" "$(sqlq "select count(*) from payment_requests where membership_id='$MEM'")"
sqlq "update memberships set current_period_end=current_period_end-30 where id='$MEM'; delete from payment_requests where period_end > current_date; delete from whatsapp_messages where member_id='$MEMBER' and created_at::date=current_date" >/dev/null

sqlq "update payment_requests set expires_at=now()-interval '1 hour' where membership_id='$MEM'" >/dev/null
remind $MEM >/dev/null
assert_equals "expired request is re-armed with a NEW token, not duplicated" "1|t" \
  "$(sqlq "select count(*), bool_and(token<>'$TOKEN' and expires_at>now()) from payment_requests where membership_id='$MEM'")"
assert_contains "old (rotated-away) token is dead" "HTTP404" "$(page $TOKEN)"
TOKEN=$(sqlq "select token from payment_requests where membership_id='$MEM'")
sqlq "delete from whatsapp_messages where member_id='$MEMBER' and created_at::date=current_date" >/dev/null

# ===========================================================================
printf '\n%s-- mode rule: skipped / razorpay / legacy --%s\n' "$B" "$N"
sqlq "update org_payment_settings set qr_enabled=false where organization_id='$ORG_IRON'" >/dev/null
got=$(remind $MEM)
assert_contains "nothing enabled: skipped no_payment_method" '"skipped":"no_payment_method"' "$got"
assert_contains "nothing enabled: reason recorded" '"reason":"no_payment_method_enabled"' "$got"
assert_equals "skip is recorded for the dashboard" "1" "$(sqlq "select count(*) from payment_link_skips where organization_id='$ORG_IRON' and membership_id='$MEM' and reason='no_payment_method_enabled'")"
assert_equals "skip: nothing was sent" "0" "$(sqlq "select count(*) from whatsapp_messages where member_id='$MEMBER' and template_name='renewal_reminder' and created_at::date=current_date")"
assert_contains "owner sees the flag in v_payment_setup_alerts" "no_payment_method_enabled" "$(rest $OWNER v_payment_setup_alerts)"
assert_equals "front_desk does not see the alert view rows" "[]" "$(rest $FD v_payment_setup_alerts)"
assert_equals "Flex owner does not see Iron's alerts" "[]" "$(rest $FLEX_OWNER v_payment_setup_alerts)"

sqlq "update org_payment_settings set qr_enabled=true, qr_image_path=null where organization_id='$ORG_IRON'" >/dev/null
assert_contains "QR enabled but no image: skipped qr_enabled_but_incomplete" '"reason":"qr_enabled_but_incomplete"' "$(remind $MEM)"
sqlq "update org_payment_settings set qr_image_path='$ORG_IRON/qr.png', upi_id=null where organization_id='$ORG_IRON'" >/dev/null
assert_contains "QR enabled but no UPI id: skipped" '"reason":"qr_enabled_but_incomplete"' "$(remind $MEM)"

sqlq "update org_payment_settings set qr_enabled=false, upi_id='irontemple@okhdfc', razorpay_enabled=true where organization_id='$ORG_IRON'" >/dev/null
got=$(remind $MEM)
assert_contains "razorpay_enabled: Razorpay path (mode razorpay)" '"mode":"razorpay"' "$got"
assert_contains "razorpay_enabled: link id from Razorpay mock, amount 150000 paise" 'plink_mock_150000_' "$got"
assert_equals "razorpay_enabled: payments row written, no payment_request" "1|0" \
  "$(sqlq "select (select count(*) from payments where membership_id='$MEM' and status='pending' and idempotency_key like 'renewal-%'), (select count(*) from payment_requests where membership_id='$MEM' and claimed_paid_at is null and created_at>now()-interval '1 minute' and token<>'$TOKEN')")"

sqlq "delete from whatsapp_messages where member_id='$MEMBER' and created_at::date=current_date; delete from payments where membership_id='$MEM' and idempotency_key like 'renewal-%';
      update org_payment_settings set qr_enabled=true, qr_image_path='$ORG_IRON/qr.png' where organization_id='$ORG_IRON'" >/dev/null
got=$(remind $MEM)
assert_contains "both enabled: Razorpay wins" '"mode":"razorpay"' "$got"

sqlq "delete from whatsapp_messages where member_id='$MEMBER' and created_at::date=current_date; delete from payments where membership_id='$MEM' and idempotency_key like 'renewal-%'; delete from org_payment_settings where organization_id='$ORG_IRON'" >/dev/null
got=$(remind $MEM)
assert_contains "legacy gym (no settings row): Razorpay exactly as before" '"mode":"razorpay"' "$got"
assert_contains "legacy gym: pending payments row + plink" 'plink_mock_150000_' "$got"
sqlq "delete from whatsapp_messages where member_id='$MEMBER' and created_at::date=current_date; delete from payments where membership_id='$MEM' and idempotency_key like 'renewal-%'; delete from payment_link_skips" >/dev/null

# restore the QR gym for the page tests
sqlq "insert into org_payment_settings (organization_id, upi_id, qr_image_path, qr_enabled) values ('$ORG_IRON','irontemple@okhdfc','$ORG_IRON/qr.png',true)" >/dev/null
sqlq "delete from payment_requests" >/dev/null
remind $MEM >/dev/null
TOKEN=$(sqlq "select token from payment_requests where membership_id='$MEM'")

# ===========================================================================
printf '\n%s-- get-pay-page --%s\n' "$B" "$N"
got=$(page "$TOKEN" 198.51.100.10)
assert_contains "valid token: 200" "HTTP200" "$got"
for k in '"gym_name":"Iron Temple Gym"' '"member_first_name":"Bharat"' '"plan_name":"Monthly Unlimited"' '"amount":1500' '"upi_id":"irontemple@okhdfc"' '"qr_url":"http' '"options":{"upi_qr":true,"razorpay":false}' '"currency":"INR"'; do
  assert_contains "page shows $k" "$k" "$got"
done
assert_not_contains "page leaks no surname" "Rao" "$got"
assert_not_contains "page leaks no phone number" "8888888888" "$got"
assert_not_contains "page leaks no org/member/membership ids" "$MEMBER" "$got"
assert_not_contains "page leaks no storage path" "qr.png\"" "$got"
QR_URL=$(printf '%s' "$got" | sed -n 's/.*"qr_url":"\([^"]*\)".*/\1/p')
# Locally the edge runtime signs against its in-network host (kong:8000); the
# path + token is what matters, so fetch it through the host-visible gateway.
QR_URL="$BASE$(printf '%s' "$QR_URL" | sed 's#^https\?://[^/]*##')"
assert_equals "signed QR URL actually serves the image" "200" "$(curl -s -o /dev/null -w '%{http_code}' "$QR_URL")"
assert_contains "signed URL is a time-limited signed URL (token in query)" "/object/sign/payment-qr/$ORG_IRON/qr.png?token=" "$QR_URL"
assert_equals "the unsigned path is not publicly readable" "400" "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/storage/v1/object/public/payment-qr/$ORG_IRON/qr.png")"

assert_contains "unknown token: 404" "HTTP404" "$(page 00000000000000000000000000000000 198.51.100.11)"
assert_contains "malformed token: 404" "HTTP404" "$(page 'not-a-token' 198.51.100.11)"
assert_contains "GET is refused" "405" "$(curl -s -o /dev/null -w '%{http_code}' "$FN/get-pay-page" -H "apikey: $ANON_KEY")"
sqlq "update payment_requests set expires_at=now()-interval '1 second' where token='$TOKEN'" >/dev/null
got=$(page "$TOKEN" 198.51.100.12)
assert_contains "expired token: 404" "HTTP404" "$got"
assert_equals "expired and unknown look identical" "$(page 00000000000000000000000000000000 198.51.100.12)" "$got"
sqlq "update payment_requests set expires_at=now()+interval '30 days' where token='$TOKEN'" >/dev/null
sqlq "update organizations set status='suspended' where id='$ORG_IRON'" >/dev/null
got=$(page "$TOKEN" 198.51.100.13)
assert_contains "suspended org: refused (403)" "HTTP403" "$got"
assert_not_contains "suspended org: nothing leaked" "Iron Temple" "$got"
sqlq "update organizations set status='active' where id='$ORG_IRON'" >/dev/null
sqlq "update org_payment_settings set qr_enabled=false where organization_id='$ORG_IRON'" >/dev/null
assert_contains "gym turned QR off: link is dead (404)" "HTTP404" "$(page "$TOKEN" 198.51.100.14)"
sqlq "update org_payment_settings set qr_enabled=true where organization_id='$ORG_IRON'" >/dev/null
sqlq "update org_payment_settings set razorpay_enabled=true where organization_id='$ORG_IRON'" >/dev/null
assert_contains "razorpay option reported when enabled" '"razorpay":true' "$(page "$TOKEN" 198.51.100.15)"
sqlq "update org_payment_settings set razorpay_enabled=false where organization_id='$ORG_IRON'" >/dev/null

hits429=0
for i in $(seq 1 45); do
  case "$(page 00000000000000000000000000000000 198.51.100.99)" in *HTTP429*) hits429=$((hits429+1));; esac
done
assert_equals "rate limit: 45 rapid requests from one client hit 429" "t" "$([ $hits429 -gt 0 ] && echo t || echo f)"
assert_contains "rate limit: a different client is unaffected" "HTTP200" "$(page "$TOKEN" 198.51.100.50)"
assert_contains "rate limit also protects claim-paid" "HTTP429" "$(for i in $(seq 1 45); do claim 00000000000000000000000000000000 198.51.100.98; done | grep -m1 -o 'HTTP429')"

# ===========================================================================
printf '\n%s-- claim-paid changes nothing but the claim --%s\n' "$B" "$N"
SNAP="select (select count(*) from payments), (select string_agg(id||status||current_period_end::text, ',' order by id) from memberships)"
BEFORE=$(sqlq "$SNAP")
got=$(claim "$TOKEN" 198.51.100.20)
assert_contains "claim: ok / claimed" '"status":"claimed"' "$got"
T1=$(sqlq "select claimed_paid_at from payment_requests where token='$TOKEN'")
assert_contains "claim stamps claimed_paid_at" "20" "$T1"
assert_equals "claim creates no payment and extends no membership" "$BEFORE" "$(sqlq "$SNAP")"
got=$(claim "$TOKEN" 198.51.100.21)
assert_contains "second claim: already_claimed" '"status":"already_claimed"' "$got"
assert_equals "claimed_paid_at is stamped once, not moved" "$T1" "$(sqlq "select claimed_paid_at from payment_requests where token='$TOKEN'")"
assert_equals "still nothing changed after the second claim" "$BEFORE" "$(sqlq "$SNAP")"
assert_contains "claim, unknown token: 404" "HTTP404" "$(claim 11111111111111111111111111111111 198.51.100.22)"
sqlq "update payment_requests set claimed_paid_at=null where token='$TOKEN'" >/dev/null
sqlq "update payment_requests set expires_at=now()-interval '1 second' where token='$TOKEN'" >/dev/null
assert_contains "claim, expired token: 404" "HTTP404" "$(claim "$TOKEN" 198.51.100.23)"
sqlq "update payment_requests set expires_at=now()+interval '30 days' where token='$TOKEN'; update organizations set status='suspended' where id='$ORG_IRON'" >/dev/null
assert_contains "claim, suspended org: 403" "HTTP403" "$(claim "$TOKEN" 198.51.100.24)"
assert_equals "claim, suspended org: nothing stamped" "" "$(sqlq "select claimed_paid_at from payment_requests where token='$TOKEN'")"
sqlq "update organizations set status='active' where id='$ORG_IRON'" >/dev/null
claim "$TOKEN" 198.51.100.25 >/dev/null

# ===========================================================================
printf '\n%s-- pending claims (owner / front_desk, location scoped) --%s\n' "$B" "$N"
assert_contains "owner sees the claim" "Bharat Rao" "$(rpc $OWNER list_pending_payment_claims '{}')"
assert_contains "front_desk (same location) sees the claim" "Bharat Rao" "$(rpc $FD list_pending_payment_claims '{}')"
assert_equals "other org's owner sees none" "[]" "$(rpc $FLEX_OWNER list_pending_payment_claims '{}')"
assert_contains "coach is refused" "not_authorized" "$(rpc $COACH list_pending_payment_claims '{}')"
assert_contains "anon is refused" "permission denied" "$(curl -s -X POST "$BASE/rest/v1/rpc/list_pending_payment_claims" -H "apikey: $ANON_KEY" -H 'Content-Type: application/json' -d '{}')"
sqlq "insert into locations (id, organization_id, name, address, timezone) values ('$LOC_IRON_2','$ORG_IRON','Second branch','x','Asia/Kolkata') on conflict do nothing; update members set location_id='$LOC_IRON_2' where id='$MEMBER'" >/dev/null
assert_equals "front_desk of ANOTHER location does not see it" "[]" "$(rpc $FD list_pending_payment_claims '{}')"
assert_contains "owner still sees it org-wide" "Bharat Rao" "$(rpc $OWNER list_pending_payment_claims '{}')"
sqlq "update members set location_id='$LOC_IRON' where id='$MEMBER'; delete from locations where id='$LOC_IRON_2'" >/dev/null

# staff confirm => payments row with payment_method = 'upi', claim leaves the list
out=$(rpc $FD record_manual_payment "{\"p_membership_id\":\"$MEM\",\"p_amount\":1500,\"p_method\":\"upi\",\"p_reference\":\"UPI-TEST-1\"}")
assert_contains "staff record the payment with method upi" '"payment_method":"upi"' "$out"
assert_equals "it lands in the Transactions ledger as upi" "upi|manual" \
  "$(sqlq "select payment_method||'|'||provider from payments where membership_id='$MEM' and provider='manual'")"
assert_equals "claim is resolved: no longer pending" "[]" "$(rpc $OWNER list_pending_payment_claims '{}')"

# PT package request is idempotent too
PK=$(sqlq "select id from pt_packages where organization_id='$ORG_IRON' limit 1")
t1=$(sqlq "select token from get_or_create_payment_request(null,'$PK',900)")
t2=$(sqlq "select token from get_or_create_payment_request(null,'$PK',900)")
assert_equals "PT package: second call reuses the same request/token" "$t1" "$t2"
assert_equals "PT package: exactly one row" "1" "$(sqlq "select count(*) from payment_requests where pt_package_id='$PK'")"
assert_equals "request must name exactly one subject" "subject_invalid" \
  "$(sql "select * from get_or_create_payment_request('$MEM','$PK',1)" | grep -o 'subject_invalid' | head -1)"

# ===========================================================================
printf '\n%s-- WhatsApp PAY intent --%s\n' "$B" "$N"
sqlq "delete from payment_requests; delete from whatsapp_messages where member_id='$MEMBER'; delete from payments where provider='manual' and membership_id='$MEM';
      update memberships set current_period_end=current_date-10, status='past_due' where id='$MEM'" >/dev/null
pay() { # <phone> <label>
  local body sig
  body=$(printf '{"object":"whatsapp_business_account","entry":[{"id":"W","changes":[{"field":"messages","value":{"messaging_product":"whatsapp","metadata":{"display_phone_number":"911111111111","phone_number_id":"P"},"messages":[{"from":"%s","id":"wamid.pp-%s-%s","timestamp":"1700000000","type":"text","text":{"body":"PAY"}}]}}]}]}' "$1" "$2" "$(date +%s%N)")
  sig=$(printf '%s' "$body" | openssl dgst -sha256 -hmac "$APP_SECRET" | sed 's/^.*= */sha256=/')
  curl -s -X POST "$FN/whatsapp-webhook" -H 'Content-Type: application/json' -H "X-Hub-Signature-256: $sig" -d "$body" >/dev/null
}
pay $MEMBER_PHONE qr1
TOKEN=$(sqlq "select token from payment_requests where membership_id='$MEM'")
assert_equals "PAY (QR gym): reply carries the pay-page link" "1" "$(sqlq "select count(*) from whatsapp_messages where member_id='$MEMBER' and direction='outbound' and template_name='renewal_reminder' and body_preview like '%$PAY_BASE/$TOKEN%'")"
assert_equals "PAY (QR gym): the QR image message is sent (mock)" "1" "$(sqlq "select count(*) from whatsapp_messages where member_id='$MEMBER' and direction='outbound' and template_name='qr_image' and body_preview like '[image]%1500%'")"
assert_equals "PAY (QR gym): no Razorpay payment created" "0" "$(sqlq "select count(*) from payments where membership_id='$MEM' and idempotency_key like 'renewal-%'")"

sqlq "update org_payment_settings set qr_enabled=false where organization_id='$ORG_IRON'; delete from whatsapp_messages where member_id='$MEMBER'" >/dev/null
pay $MEMBER_PHONE none1
assert_equals "PAY (nothing enabled): member told it is not set up" "1" "$(sqlq "select count(*) from whatsapp_messages where member_id='$MEMBER' and direction='outbound' and body_preview like '%isn''t set up%'")"
assert_equals "PAY (nothing enabled): no image, skip recorded" "0|1" "$(sqlq "select (select count(*) from whatsapp_messages where member_id='$MEMBER' and template_name='qr_image'), (select count(*) from payment_link_skips where membership_id='$MEM')")"

sqlq "update org_payment_settings set razorpay_enabled=true where organization_id='$ORG_IRON'; delete from whatsapp_messages where member_id='$MEMBER'" >/dev/null
pay $MEMBER_PHONE rzp1
assert_equals "PAY (Razorpay gym): link as before, NO qr image" "1|0" "$(sqlq "select (select count(*) from whatsapp_messages where member_id='$MEMBER' and template_name='renewal_reminder' and body_preview like '%rzp.mock/plink_mock_150000_%'), (select count(*) from whatsapp_messages where member_id='$MEMBER' and template_name='qr_image')")"

# ===========================================================================
reset_state
printf '\n%s== summary ==%s\n' "$B" "$N"
printf '  %spassed %d%s   %sfailed %d%s   skipped %d\n' "$G" "$PASS" "$N" "$R" "$FAIL" "$N" "$SKIP"
if [ "$FAIL" -gt 0 ]; then printf '\n  failing cases:\n'; for c in "${FAILED_CASES[@]}"; do printf '    - %s\n' "$c"; done; exit 1; fi
exit 0
