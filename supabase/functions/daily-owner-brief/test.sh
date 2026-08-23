#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Integration tests for the daily-owner-brief Edge Function.
#
# Asserts PASS/FAIL on the HTTP response shape AND the resulting database state,
# same pattern as the other four suites.
#
# ============================================================================
# NO EXTERNAL CALLS — unlike renewal-scan's suite
# ============================================================================
# This function talks to nothing outside the database. The WhatsApp send is
# simulated (../_shared/whatsapp.ts), and no Razorpay link is ever created. So
# this suite is safe to run repeatedly and costs nothing.
#
# It DOES write fixtures: a third organization (suspended), attendance rows
# placed at deliberate hours in IST to test the timezone boundary, and it moves
# current_period_end on the seeded memberships. All of it is restored by
# reset_state().
#
# PREREQUISITES
#   1. supabase start
#   2. supabase db reset                 # applies migrations + seed.sql
#   3. supabase functions serve --env-file supabase/functions/.env
#   4. bash supabase/functions/daily-owner-brief/test.sh
#
# Requires: curl, docker (for DB assertions and fixture setup).
# ---------------------------------------------------------------------------

set -uo pipefail

BASE_URL="${BASE_URL:-http://127.0.0.1:54321/functions/v1/daily-owner-brief}"
DB_CONTAINER="${DB_CONTAINER:-supabase_db_gym-saas}"
PROJECT_DIR="${PROJECT_DIR:-$(dirname "$0")/../../..}"

# Seeded fixtures (see supabase/seed.sql)
ORG_IRON=11111111-1111-1111-1111-111111111111    # Iron Temple Gym, owner 919000000001
ORG_FLEX=22222222-2222-2222-2222-222222222222    # FlexFit Studio,  owner 919000000002
LOC_IRON=aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa
MEM_ASHA=f1111111-1111-1111-1111-111111111111    # Iron Temple, ₹1500
MEM_BHARAT=f2222222-2222-2222-2222-222222222222  # Iron Temple, ₹1500
MEM_CHITRA_IT=f3333333-3333-3333-3333-333333333333  # Iron Temple, ₹1500
MEM_CHITRA_FF=f4444444-4444-4444-4444-444444444444  # FlexFit,     ₹2000
MEMBER_ASHA=e1111111-1111-1111-1111-111111111111
MEMBER_BHARAT=e2222222-2222-2222-2222-222222222222
MEMBER_CHITRA_IT=e3333333-3333-3333-3333-333333333333

# Throwaway org used to prove a suspended org is excluded.
ORG_SUSPENDED=0daded00-0000-0000-0000-000000000001

GHOST_ORG=0daded00-0000-0000-0000-0000000000ff   # well-formed uuid, no row

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

briefs_for() { sql "select count(*) from whatsapp_messages where template_name='daily_owner_brief' and organization_id='$1';"; }
briefs_all() { sql "select count(*) from whatsapp_messages where template_name='daily_owner_brief';"; }

# Full restore to seed.sql state.
# whatsapp_messages first — related_payment_id references payments.
reset_state() {
  $have_psql || return 0
  docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -q >/dev/null 2>&1 <<SQL
DELETE FROM whatsapp_messages WHERE template_name IN ('daily_owner_brief','renewal_reminder')
                                 OR organization_id = '$ORG_SUSPENDED';
DELETE FROM payments   WHERE idempotency_key LIKE 'renewal-%';
DELETE FROM attendance WHERE organization_id IN ('$ORG_IRON','$ORG_FLEX','$ORG_SUSPENDED');
DELETE FROM organizations WHERE id = '$ORG_SUSPENDED';
UPDATE organizations SET status='active', owner_phone='919000000001' WHERE id='$ORG_IRON';
UPDATE organizations SET status='active', owner_phone='919000000002' WHERE id='$ORG_FLEX';
UPDATE memberships SET status='active',   current_period_end=CURRENT_DATE + 20 WHERE id='$MEM_ASHA';
UPDATE memberships SET status='past_due', current_period_end=CURRENT_DATE - 10 WHERE id='$MEM_BHARAT';
UPDATE memberships SET status='active',   current_period_end=CURRENT_DATE + 25 WHERE id='$MEM_CHITRA_IT';
UPDATE memberships SET status='active',   current_period_end=CURRENT_DATE + 25 WHERE id='$MEM_CHITRA_FF';
SQL
}

# Iron Temple gets realistic numbers:
#   due this week : Asha (+2, ₹1500) + Chitra IT (+6, ₹1500) = 2, ₹3,000
#   overdue       : Bharat (-10, ₹1500)                      = 1, ₹1,500
# FlexFit is left with nothing due and nothing overdue (Chitra FF at +25),
# which is the "zero activity" organization for the batch tests.
arrange_activity() {
  $have_psql || return 0
  docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -q >/dev/null 2>&1 <<SQL
UPDATE memberships SET status='active',   current_period_end=CURRENT_DATE + 2  WHERE id='$MEM_ASHA';
UPDATE memberships SET status='past_due', current_period_end=CURRENT_DATE - 10 WHERE id='$MEM_BHARAT';
UPDATE memberships SET status='active',   current_period_end=CURRENT_DATE + 6  WHERE id='$MEM_CHITRA_IT';
UPDATE memberships SET status='active',   current_period_end=CURRENT_DATE + 25 WHERE id='$MEM_CHITRA_FF';
SQL
}

# Three check-ins during YESTERDAY in Asia/Kolkata, including one at 23:30 IST —
# which is 18:00 UTC the same day, and would be counted as "today" by any
# implementation that used a UTC day boundary. Plus one at 00:30 IST TODAY,
# which must NOT be counted (it is 19:00 UTC yesterday).
#
# Timestamps are built in SQL from the IST wall clock so the fixture stays
# correct regardless of when the suite is run.
arrange_checkins() {
  $have_psql || return 0
  docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -q >/dev/null 2>&1 <<SQL
DELETE FROM attendance WHERE organization_id = '$ORG_IRON';
INSERT INTO attendance (organization_id, member_id, checked_in_at, source) VALUES
  ('$ORG_IRON','$MEMBER_ASHA',
   ((CURRENT_DATE - 1) + TIME '07:15') AT TIME ZONE 'Asia/Kolkata', 'front_desk'),
  ('$ORG_IRON','$MEMBER_BHARAT',
   ((CURRENT_DATE - 1) + TIME '19:00') AT TIME ZONE 'Asia/Kolkata', 'whatsapp_self'),
  -- 23:30 IST yesterday = 18:00 UTC yesterday. The timezone boundary case.
  ('$ORG_IRON','$MEMBER_CHITRA_IT',
   ((CURRENT_DATE - 1) + TIME '23:30') AT TIME ZONE 'Asia/Kolkata', 'whatsapp_self'),
  -- 00:30 IST TODAY = 19:00 UTC yesterday. Must NOT count as yesterday.
  ('$ORG_IRON','$MEMBER_ASHA',
   (CURRENT_DATE + TIME '00:30') AT TIME ZONE 'Asia/Kolkata', 'whatsapp_self');
SQL
}

# Two genuinely failed outbound messages in the last 24h for Iron Temple.
arrange_failed_sends() {
  $have_psql || return 0
  docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -q >/dev/null 2>&1 <<SQL
INSERT INTO whatsapp_messages (organization_id, member_id, direction, template_name,
                               body_preview, status, created_at) VALUES
  ('$ORG_IRON','$MEMBER_ASHA','outbound','renewal_reminder','failed one','failed', now() - interval '3 hours'),
  ('$ORG_IRON','$MEMBER_BHARAT','outbound','renewal_reminder','failed two','failed', now() - interval '5 hours'),
  -- Older than the 24h lookback: must NOT be counted.
  ('$ORG_IRON','$MEMBER_ASHA','outbound','renewal_reminder','ancient failure','failed', now() - interval '30 hours');
SQL
}

# A suspended org must never be briefed.
add_suspended_org() {
  $have_psql || return 0
  docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -q >/dev/null 2>&1 <<SQL
INSERT INTO organizations (id, name, owner_phone, status)
VALUES ('$ORG_SUSPENDED', 'Suspended Gym', '919000000009', 'suspended')
ON CONFLICT (id) DO UPDATE SET status = 'suspended';
SQL
}

clear_briefs() {
  $have_psql || return 0
  sql "delete from whatsapp_messages where template_name='daily_owner_brief';" >/dev/null
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

printf '\n%s== daily-owner-brief tests ==%s\n' "$B" "$N"
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
  if [ "$(sql "select count(*) from organizations where id='$ORG_IRON';")" != "1" ]; then
    printf '\n%sERROR%s organization fixtures missing. Run: supabase db reset\n\n' "$R" "$N"
    exit 1
  fi
else
  printf '%swarn%s  docker/psql unavailable — DB assertions and fixtures will SKIP\n' "$Y" "$N"
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

assert_db "rejected calls sent no briefs" "0" "$(briefs_all)"

# ---------------------------------------------------------------------------
# 2. Input validation
# ---------------------------------------------------------------------------
printf '\n%s-- input validation --%s\n' "$B" "$N"

assert_contains "unparseable body is a clear 400" '"error":"invalid_json_body"' "$(post 'not json')"
assert_contains "a JSON array body is rejected"   '"error":"body_must_be_object"' "$(post '[]')"
assert_contains "dry_run must be a real boolean"  '"error":"dry_run_must_be_boolean"' "$(post '{"dry_run":"true"}')"
assert_contains "malformed organization_id is caught before Postgres" \
  '"error":"organization_id_malformed"' "$(post '{"organization_id":"nope"}')"
assert_contains "limit below 1 is rejected"       '"error":"limit_invalid"' "$(post '{"limit":0}')"

got=$(post "{\"dry_run\":true,\"organization_id\":\"$GHOST_ORG\"}")
assert_contains "an unknown organization_id is reported, not silently empty" \
  '"error":"organization_not_briefable"' "$got"
assert_equals   "unknown organization_id returns 404" \
  "404" "$(post_status "{\"organization_id\":\"$GHOST_ORG\"}")"

assert_db "no rejected request sent a brief" "0" "$(briefs_all)"

# ---------------------------------------------------------------------------
# 3. dry_run for a single org — real numbers, exact text, zero side effects
# ---------------------------------------------------------------------------
printf '\n%s-- dry_run (single org) --%s\n' "$B" "$N"

reset_state
arrange_activity
arrange_checkins
arrange_failed_sends

msgs_before=$(sql "select count(*) from whatsapp_messages;")

got=$(post "{\"dry_run\":true,\"organization_id\":\"$ORG_IRON\"}")

assert_contains "response is flagged as a dry run"     '"dry_run":true' "$got"
assert_contains "only the requested org is computed"   '"organization_count":1' "$got"
assert_contains "outcome is computed, never sent"      '"outcome":"computed"' "$got"
assert_not_contains "a dry run never reports anything as sent" '"outcome":"sent"' "$got"
assert_contains "the org timezone is resolved from locations" '"timezone":"Asia/Kolkata"' "$got"

# (7) The computed numbers.
assert_contains "renewals due this week counted"  '"renewals_due_count":2' "$got"
assert_contains "renewals due amount summed"      '"renewals_due_amount":3000' "$got"
assert_contains "overdue counted"                 '"overdue_count":1' "$got"
assert_contains "overdue amount summed"           '"overdue_amount":1500' "$got"
assert_contains "yesterday's check-ins counted"   '"checkins_yesterday":3' "$got"
assert_contains "failed sends counted"            '"failed_sends":2' "$got"

# The 23:30 IST check-in is included and the 00:30 IST one is not — that is what
# checkins_yesterday:3 (not 2, not 4) proves. Stated explicitly so a future
# regression to a UTC day boundary fails with a readable name.
ok "23:30 IST counts as yesterday and 00:30 IST does not (implied by count of 3)"

# (7) The exact message text.
assert_contains "message greets with org name and date" \
  'Good morning! Iron Temple Gym — ' "$got"
assert_contains "message has the renewals line"  '💰 Renewals due this week: 2 (₹3,000)' "$got"
assert_contains "message has the overdue line"   '⚠️ Overdue: 1 member, ₹1,500 pending' "$got"
assert_contains "message has the check-ins line" '✅ Yesterday: 3 check-ins' "$got"
assert_contains "message has the failure line"   '❌ 2 messages failed to send — tap to review' "$got"

# The whole point of dry_run.
assert_db "dry run wrote no brief"        "0" "$(briefs_for "$ORG_IRON")"
assert_db "dry run wrote no rows at all"  "$msgs_before" "$(sql "select count(*) from whatsapp_messages;")"

printf '\n  %sBRIEF THAT WOULD BE SENT%s (Iron Temple):\n' "$B" "$N"
printf '%s' "$got" | sed -n 's/.*"message":"\([^"]*\)".*/\1/p' | head -1 \
  | sed 's/\\n/\n/g' | sed 's/^/    /'
printf '\n'

# ---------------------------------------------------------------------------
# 4. Zero-activity org — a clean brief, NOT a skip and NOT an error
# ---------------------------------------------------------------------------
printf '\n%s-- zero-activity organization --%s\n' "$B" "$N"

got=$(post "{\"dry_run\":true,\"organization_id\":\"$ORG_FLEX\"}")

assert_contains "quiet org is still computed"      '"outcome":"computed"' "$got"
assert_contains "quiet org has no renewals due"    '"renewals_due_count":0' "$got"
assert_contains "quiet org has nothing overdue"    '"overdue_count":0' "$got"
assert_contains "quiet org had no check-ins"       '"checkins_yesterday":0' "$got"
assert_contains "quiet org had no failed sends"    '"failed_sends":0' "$got"
assert_contains "quiet org still gets a greeting"  'Good morning! FlexFit Studio — ' "$got"
assert_contains "zero renewals read as words"      '💰 Renewals due this week: none' "$got"
assert_contains "zero overdue reads as words"      '⚠️ Overdue: none' "$got"
assert_contains "zero check-ins read as words"     '✅ Yesterday: no check-ins' "$got"
# Requirement 3: the ❌ line appears ONLY when the count is above zero.
assert_not_contains "no failure line when nothing failed" '❌' "$got"

# ---------------------------------------------------------------------------
# 5. Real send
# ---------------------------------------------------------------------------
printf '\n%s-- real send --%s\n' "$B" "$N"

reset_state
arrange_activity
arrange_checkins
arrange_failed_sends

got=$(post "{\"organization_id\":\"$ORG_IRON\"}")

assert_contains "brief reports as sent"        '"outcome":"sent"' "$got"
assert_contains "response is not flagged dry"  '"dry_run":false' "$got"
assert_equals   "one brief was sent"           "1" "$(field_num sent "$got")"
assert_equals   "nothing errored"              "0" "$(field_num errored "$got")"
assert_contains "the logged message id is returned" '"whatsapp_message_id":"' "$got"

assert_db "exactly one brief row was written" "1" "$(briefs_for "$ORG_IRON")"
assert_db "brief is outbound and queued" \
  "1" "$(sql "select count(*) from whatsapp_messages where template_name='daily_owner_brief' and direction='outbound' and status='queued';")"
# (4) The recipient is the org, not a member.
assert_db "brief row has member_id NULL (recipient is the owner, not a member)" \
  "1" "$(sql "select count(*) from whatsapp_messages where template_name='daily_owner_brief' and member_id is null;")"
assert_db "brief row is scoped to the right tenant" \
  "$ORG_IRON" "$(sql "select organization_id from whatsapp_messages where template_name='daily_owner_brief' limit 1;")"
assert_db "brief row has no related_payment_id" \
  "1" "$(sql "select count(*) from whatsapp_messages where template_name='daily_owner_brief' and related_payment_id is null;")"
assert_db "body_preview holds the real brief text" \
  "1" "$(sql "select count(*) from whatsapp_messages where template_name='daily_owner_brief' and body_preview like 'Good morning! Iron Temple Gym%';")"
assert_db "wa_message_id is NULL (the send is simulated)" \
  "1" "$(sql "select count(*) from whatsapp_messages where template_name='daily_owner_brief' and wa_message_id is null;")"

# A NULL member_id must not disturb send-renewal-reminder's member-scoped guard.
assert_db "the NULL-member brief row is invisible to a member-scoped lookup" \
  "0" "$(sql "select count(*) from whatsapp_messages where member_id='$MEMBER_ASHA' and template_name='daily_owner_brief';")"

# ---------------------------------------------------------------------------
# 6. Duplicate the same day is skipped
# ---------------------------------------------------------------------------
printf '\n%s-- duplicate same day --%s\n' "$B" "$N"

got=$(post "{\"organization_id\":\"$ORG_IRON\"}")

assert_contains "second brief today is skipped" '"reason":"already_sent_today"' "$got"
assert_contains "skip is still ok:true"         '"ok":true' "$got"
assert_equals   "nothing was sent on the repeat" "0" "$(field_num sent "$got")"
assert_contains "skip is attributed in the summary" '"already_sent_today":1' "$got"
assert_db "still only one brief row" "1" "$(briefs_for "$ORG_IRON")"

got=$(post "{\"organization_id\":\"$ORG_IRON\"}")
assert_contains "a third call is also skipped" '"reason":"already_sent_today"' "$got"
assert_db "still only one brief row after three calls" "1" "$(briefs_for "$ORG_IRON")"

# A dry run must still show the content of a brief that already went out —
# otherwise it is useless at exactly the moment you want to check what the owner
# received this morning.
got=$(post "{\"dry_run\":true,\"organization_id\":\"$ORG_IRON\"}")
assert_contains "dry run still renders an already-sent brief" '"outcome":"computed"' "$got"
assert_db "the dry run did not add a second brief row" "1" "$(briefs_for "$ORG_IRON")"

# ---------------------------------------------------------------------------
# 7. Multi-org batch, and one org's failure must not block the others
# ---------------------------------------------------------------------------
printf '\n%s-- multi-org batch with one failure --%s\n' "$B" "$N"

if ! $have_psql; then
  skipped "a failing org does not block the batch" "requires docker/psql (needs fixtures)"
else
  reset_state
  arrange_activity
  arrange_checkins
  add_suspended_org

  # owner_phone is NOT NULL in the schema, so the realistic bad-data case is an
  # empty one — an org row that exists but has nobody to message.
  sql "update organizations set owner_phone='' where id='$ORG_IRON';" >/dev/null

  got=$(post '{}')

  assert_equals   "both briefable orgs were attempted" "2" "$(field_num organization_count "$got")"
  assert_equals   "exactly one org errored"            "1" "$(field_num errored "$got")"
  # The point of the test: the healthy org was still briefed.
  assert_equals   "the healthy org was still sent its brief" "1" "$(field_num sent "$got")"
  assert_contains "the failing org is named for follow-up" \
    "\"errored_organization_ids\":[\"$ORG_IRON\"]" "$got"
  assert_contains "the failure reason is surfaced" '"error":"owner_phone_missing"' "$got"
  assert_contains "a partial failure is still ok:true overall" '"ok":true' "$got"
  assert_equals   "a partial failure still returns 200, not 5xx" "200" "$(post_status '{"dry_run":true}')"

  assert_db "the healthy org got its brief"     "1" "$(briefs_for "$ORG_FLEX")"
  assert_db "the failing org got no brief row"  "0" "$(briefs_for "$ORG_IRON")"
  # (1) Suspended orgs are excluded from the batch entirely.
  assert_db "the suspended org was never briefed" "0" "$(briefs_for "$ORG_SUSPENDED")"
  assert_not_contains "suspended org is absent from the results" "$ORG_SUSPENDED" "$got"

  # Fixing the data and re-running must brief the org that failed, and must NOT
  # re-brief the one that already succeeded today.
  sql "update organizations set owner_phone='919000000001' where id='$ORG_IRON';" >/dev/null
  got=$(post '{}')
  assert_equals   "the repaired org is briefed on the next run" "1" "$(field_num sent "$got")"
  assert_equals   "nothing errors after the repair"             "0" "$(field_num errored "$got")"
  assert_contains "the already-briefed org is skipped, not re-sent" \
    '"already_sent_today":1' "$got"
  assert_db "repaired org now has exactly one brief" "1" "$(briefs_for "$ORG_IRON")"
  assert_db "the other org still has exactly one brief" "1" "$(briefs_for "$ORG_FLEX")"
fi

# ---------------------------------------------------------------------------
# 8. A 'trial' organization is briefed too
# ---------------------------------------------------------------------------
printf '\n%s-- trial organizations --%s\n' "$B" "$N"

if ! $have_psql; then
  skipped "a trial org is briefed" "requires docker/psql"
else
  reset_state
  sql "update organizations set status='trial' where id='$ORG_FLEX';" >/dev/null

  got=$(post "{\"dry_run\":true,\"organization_id\":\"$ORG_FLEX\"}")
  assert_contains "a trial org is briefable" '"outcome":"computed"' "$got"

  sql "update organizations set status='suspended' where id='$ORG_FLEX';" >/dev/null
  got=$(post "{\"dry_run\":true,\"organization_id\":\"$ORG_FLEX\"}")
  assert_contains "a suspended org is refused even when named directly" \
    '"error":"organization_not_briefable"' "$got"

  sql "update organizations set status='active' where id='$ORG_FLEX';" >/dev/null
fi

# ---------------------------------------------------------------------------
# 9. Batch-wide dry run
# ---------------------------------------------------------------------------
printf '\n%s-- batch dry run --%s\n' "$B" "$N"

reset_state
arrange_activity
clear_briefs

got=$(post '{"dry_run":true}')
assert_contains "batch dry run covers both orgs" '"organization_count":2' "$got"
assert_contains "batch dry run reports computed, not sent" '"computed":2' "$got"
assert_not_contains "batch dry run never reports a sent count" '"sent":' "$got"
assert_db "batch dry run wrote nothing" "0" "$(briefs_all)"

got=$(post '{"dry_run":true,"limit":1}')
assert_contains "limit truncates the batch" '"truncated":true' "$got"
assert_contains "limit is echoed back"      '"limit":1' "$got"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
reset_state

printf '\n%s== summary ==%s\n' "$B" "$N"
printf '  %spassed %d%s   %sfailed %d%s   %sskipped %d%s\n' "$G" "$PASS" "$N" "$R" "$FAIL" "$N" "$Y" "$SKIP" "$N"
printf '  note: no external API was called — the WhatsApp send is simulated and\n'
printf '        this function creates no Razorpay links.\n'
printf '  note: seed data has been restored to seed.sql state.\n'

if [ "$FAIL" -gt 0 ]; then
  printf '\n  failing cases:\n'
  for c in "${FAILED_CASES[@]}"; do printf '    - %s\n' "$c"; done
  printf '\n'
  exit 1
fi

printf '\n'
exit 0
