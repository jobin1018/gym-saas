#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# MANUAL, BY-HAND smoke test: creates ONE REAL Razorpay TEST-MODE payment link.
#
# NOT part of run-all-tests.sh. Run it yourself, deliberately, when you want
# proof that the real (non-mock) Razorpay path still works end to end.
#
#   1. Put REAL rzp_test_ keys in supabase/functions/.env and REMOVE (or set to
#      anything but "mock") RAZORPAY_MODE there. Keep WHATSAPP_SEND_MODE=mock.
#   2. supabase functions serve --env-file supabase/functions/.env
#   3. bash supabase/functions/send-renewal-reminder/smoke-real-razorpay.sh
#
# Refuses to run against rzp_live_ keys, in mock mode, or with real WhatsApp
# sending on. Check the link in the Razorpay TEST dashboard afterwards.
# ---------------------------------------------------------------------------
set -uo pipefail
ENV_FILE="${ENV_FILE:-$(dirname "$0")/../.env}"
read_env() { [ -f "$ENV_FILE" ] && sed -n "s/^[[:space:]]*$1=//p" "$ENV_FILE" | tail -1 | tr -d '\r"'; }
KEY="${RAZORPAY_KEY_ID:-$(read_env RAZORPAY_KEY_ID)}"
RMODE="${RAZORPAY_MODE:-$(read_env RAZORPAY_MODE)}"
WMODE="${WHATSAPP_SEND_MODE:-$(read_env WHATSAPP_SEND_MODE)}"
[ "$(echo "$RMODE" | tr A-Z a-z)" = "mock" ] && { echo "REFUSING: RAZORPAY_MODE=mock — this smoke test is for the REAL path."; exit 1; }
[ "$(echo "$WMODE" | tr A-Z a-z)" = "mock" ] || { echo "REFUSING: WHATSAPP_SEND_MODE must be mock."; exit 1; }
case "$KEY" in rzp_test_*) ;; *) echo "REFUSING: RAZORPAY_KEY_ID must be an rzp_test_ key."; exit 1;; esac
SERVICE_KEY=$(cd "$(dirname "$0")/../../.." && supabase status -o env 2>/dev/null | sed -n 's/^SERVICE_ROLE_KEY="\(.*\)"$/\1/p' | tail -1)
URL="${BASE_URL:-http://127.0.0.1:54321/functions/v1/send-renewal-reminder}"
MEM=f2222222-2222-2222-2222-222222222222   # seeded past_due membership (Iron Temple)
docker exec supabase_db_gym-saas psql -U postgres -c "delete from whatsapp_messages where member_id='e2222222-2222-2222-2222-222222222222' and template_name='renewal_reminder' and created_at::date=current_date" >/dev/null
out=$(curl -s -X POST "$URL" -H "authorization: Bearer $SERVICE_KEY" -H "content-type: application/json" -d "{\"membership_id\":\"$MEM\"}")
echo "$out"
if echo "$out" | grep -q '"razorpay_link_id":"plink_' && ! echo "$out" | grep -q 'plink_mock'; then
  echo "PASS: a real Razorpay test-mode link was created. Verify it in the dashboard."
else
  echo "FAIL: no real plink_ id in the response."; exit 1
fi
