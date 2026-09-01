#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Integration tests for the validate-magic-link Edge Function — redeeming a
# coach's one-time WhatsApp magic-link token for a real coach session, no PIN.
#
# Covers the security-critical properties the feature spec calls out:
#   * a link works exactly ONCE, then every reuse fails
#   * a link past its 15-minute window fails as expired
#   * a malformed / unknown token gives a clean error, never a crash
#   * a link for a deactivated (or no-longer-)coach is refused
#   * end to end: a coach texts SESSION -> whatsapp-webhook mints the link ->
#     this function redeems it -> a second redemption of that same link fails
#
# No external API. The end-to-end block drives whatsapp-webhook with a signed
# mock-Meta envelope (WHATSAPP_SEND_MODE=mock, same guard as that suite) and
# reads the generated link back out of whatsapp_messages.body_preview.
#
# PREREQUISITES: supabase start; supabase db reset; supabase functions serve
#   --env-file supabase/functions/.env ; then run this file.
# Requires: curl, docker (psql). openssl only for the end-to-end block.
# ---------------------------------------------------------------------------

set -uo pipefail

BASE="${BASE_URL:-http://127.0.0.1:54321}"
VML_URL="$BASE/functions/v1/validate-magic-link"
WH_URL="$BASE/functions/v1/whatsapp-webhook"
REST_URL="$BASE/rest/v1"
DB_CONTAINER="${DB_CONTAINER:-supabase_db_gym-saas}"
PROJECT_DIR="${PROJECT_DIR:-$(dirname "$0")/../../..}"
ENV_FILE="${ENV_FILE:-$(dirname "$0")/../.env}"

ORG_IRON=11111111-1111-1111-1111-111111111111
ORG_FLEX=22222222-2222-2222-2222-222222222222
LOC_IRON=aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa

# Seeded coach (see supabase/seed.sql): Farah Sheikh, Iron Temple.
FARAH_ID=c0ac0000-0000-0000-0000-000000000001
FARAH_PHONE=918454000001

# Throwaway deactivated coach this suite owns (collides with nothing in seed).
DEACT_COACH_ID=0daded00-9999-0000-0000-000000000001
DEACT_COACH_PHONE=919000079901

PASS=0; FAIL=0; SKIP=0
FAILED_CASES=()
if [ -t 1 ]; then G=$'\033[32m'; R=$'\033[31m'; Y=$'\033[33m'; B=$'\033[1m'; N=$'\033[0m'
else G=""; R=""; Y=""; B=""; N=""; fi
ok()  { PASS=$((PASS+1)); printf '  %sPASS%s  %s\n' "$G" "$N" "$1"; }
bad() { FAIL=$((FAIL+1)); FAILED_CASES+=("$1"); printf '  %sFAIL%s  %s\n' "$R" "$N" "$1"
        printf '        expected: %s\n        actual:   %s\n' "$2" "$3"; }
skipped() { SKIP=$((SKIP+1)); printf '  %sSKIP%s  %s\n           %s\n' "$Y" "$N" "$1" "$2"; }
assert_contains()     { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "contains '$2'" "$3" ;; esac; }
assert_not_contains() { case "$3" in *"$2"*) bad "$1" "does NOT contain '$2'" "$3" ;; *) ok "$1" ;; esac; }
assert_equals()       { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "$2" "$3"; fi; }

read_env() { [ -f "$ENV_FILE" ] || return 0; sed -n "s/^[[:space:]]*$1=//p" "$ENV_FILE" | tail -1 | tr -d '\r"'; }

ANON_KEY="${ANON_KEY:-}"
if [ -z "$ANON_KEY" ] && command -v supabase >/dev/null 2>&1; then
  ANON_KEY=$( (cd "$PROJECT_DIR" && supabase status -o env 2>/dev/null) | sed -n 's/^ANON_KEY="\(.*\)"$/\1/p' | tail -1 )
fi
APP_SECRET="${META_APP_SECRET:-$(read_env META_APP_SECRET)}"
WA_SEND_MODE="${WHATSAPP_SEND_MODE:-$(read_env WHATSAPP_SEND_MODE)}"

have_psql=false
if docker exec "$DB_CONTAINER" true >/dev/null 2>&1; then have_psql=true; fi
have_openssl=false
if command -v openssl >/dev/null 2>&1; then have_openssl=true; fi

sql()  { docker exec "$DB_CONTAINER" psql -U postgres -d postgres -tAc "$1" 2>/dev/null | tr -d '\r'; }
sqlq() { docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -q >/dev/null 2>&1; }

vml()        { curl -s -X POST "$VML_URL" -H "Authorization: Bearer $ANON_KEY" -H 'Content-Type: application/json' -d "$1"; }
vml_status() { curl -s -o /dev/null -w '%{http_code}' -X POST "$VML_URL" -H "Authorization: Bearer $ANON_KEY" -H 'Content-Type: application/json' -d "$1"; }

# A fresh base64url token (32 bytes -> 43 chars), matching the generator's shape.
new_token() { openssl rand 32 | base64 | tr '+/' '-_' | tr -d '=\n'; }

# Insert a coach_magic_links row directly. <token> <coach_id> <org> <expires-sql> [used-sql]
insert_link() {
  docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -q >/dev/null 2>&1 <<SQL
INSERT INTO coach_magic_links (coach_user_id, organization_id, token, expires_at, used_at)
VALUES ('$2', '$3', '$1', $4, ${5:-NULL});
SQL
}

reset_state() {
  $have_psql || return 0
  docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -q >/dev/null 2>&1 <<SQL
DELETE FROM coach_magic_links WHERE coach_user_id IN ('$FARAH_ID', '$DEACT_COACH_ID');
DELETE FROM training_notes  WHERE coach_id = '$DEACT_COACH_ID';
DELETE FROM users           WHERE id = '$DEACT_COACH_ID';
DELETE FROM whatsapp_messages
  WHERE organization_id = '$ORG_IRON' AND body_preview LIKE '%coach/quick-log%';
SQL
}
arrange() {
  $have_psql || return 0
  docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -q >/dev/null 2>&1 <<SQL
INSERT INTO users (id, organization_id, name, phone, role, location_id, active)
VALUES ('$DEACT_COACH_ID', '$ORG_IRON', 'Deactivated Coach', '$DEACT_COACH_PHONE', 'coach', '$LOC_IRON', false);
SQL
}

printf '\n%s== validate-magic-link tests ==%s\n' "$B" "$N"
printf 'target: %s\n' "$VML_URL"
if [ -z "$ANON_KEY" ]; then printf '\n%sERROR%s no anon key. Run `supabase status`.\n\n' "$R" "$N"; exit 1; fi
if ! $have_psql; then printf '\n%sERROR%s needs docker/psql.\n\n' "$R" "$N"; exit 1; fi
if ! curl -s -o /dev/null --max-time 5 -X POST "$VML_URL" -H "Authorization: Bearer $ANON_KEY" -d '{}'; then
  printf '\n%sERROR%s cannot reach validate-magic-link. Start `supabase functions serve`.\n\n' "$R" "$N"; exit 1
fi

reset_state
arrange

# ---------------------------------------------------------------------------
# 0. CORS + method + input validation — a bad token must never crash
# ---------------------------------------------------------------------------
printf '\n%s-- CORS + method + input validation --%s\n' "$B" "$N"
pf=$(curl -s -i -X OPTIONS "$VML_URL" -H "Origin: https://app.example.com" -H "Access-Control-Request-Method: POST" | tr '[:upper:]' '[:lower:]')
assert_contains "OPTIONS preflight answered 200"      "http/1.1 200" "$pf"
assert_equals   "GET is rejected"                     "405" "$(curl -s -o /dev/null -w '%{http_code}' -X GET "$VML_URL" -H "Authorization: Bearer $ANON_KEY")"
assert_contains "unparseable body -> 400"             '"error":"invalid_json_body"' "$(vml 'not json')"
assert_contains "missing token -> 400"                '"error":"token_malformed"'  "$(vml '{}')"
assert_contains "too-short token -> 400 (never hits the DB)" '"error":"token_malformed"' "$(vml '{"token":"abc"}')"
assert_contains "token with illegal chars -> 400"     '"error":"token_malformed"'  "$(vml '{"token":"'"$(printf 'a%.0s' {1..40})"'!!"}')"
assert_equals   "  ...malformed token is a clean 400, not a 500" "400" "$(vml_status '{"token":"abc"}')"

# ---------------------------------------------------------------------------
# 1. Well-formed but unknown token -> clean 404, no crash
# ---------------------------------------------------------------------------
printf '\n%s-- unknown token --%s\n' "$B" "$N"
GHOST=$(new_token)
assert_contains "well-formed unknown token -> invalid_token" '"error":"invalid_token"' "$(vml "{\"token\":\"$GHOST\"}")"
assert_equals   "  ...404, not 500"                          "404" "$(vml_status "{\"token\":\"$GHOST\"}")"

# ---------------------------------------------------------------------------
# 2. Happy path — a valid link redeems once for a real coach session
# ---------------------------------------------------------------------------
printf '\n%s-- redeem a valid link (once) --%s\n' "$B" "$N"
T_OK=$(new_token)
insert_link "$T_OK" "$FARAH_ID" "$ORG_IRON" "now() + interval '15 minutes'"
got=$(vml "{\"token\":\"$T_OK\"}")
assert_contains "valid link -> ok:true"                 '"ok":true' "$got"
assert_contains "  ...returns an access_token"          '"access_token":"' "$got"
assert_contains "  ...returns a refresh_token"          '"refresh_token":"' "$got"
assert_contains "  ...session is scoped role=coach"     '"role":"coach"' "$got"
assert_contains "  ...and to the coach's own org"       "\"organization_id\":\"$ORG_IRON\"" "$got"
assert_equals   "  ...the row is now marked used"       "t" "$(sql "select (used_at is not null) from coach_magic_links where token='$T_OK'")"

# The minted token is a genuine session: it can read the coach's own clients.
AT=$(printf '%s' "$got" | sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p')
pkg=$(curl -s "$REST_URL/pt_packages?select=id&coach_id=eq.$FARAH_ID&status=eq.active" -H "apikey: $ANON_KEY" -H "Authorization: Bearer $AT")
assert_contains "minted session can read pt_packages under normal RLS" '"id":' "$pkg"

# ---------------------------------------------------------------------------
# 3. Reuse — a second redemption of the same link fails
# ---------------------------------------------------------------------------
printf '\n%s-- reuse is refused --%s\n' "$B" "$N"
assert_contains "redeeming the same link again -> link_already_used" '"error":"link_already_used"' "$(vml "{\"token\":\"$T_OK\"}")"
assert_equals   "  ...410, not 200"                                  "410" "$(vml_status "{\"token\":\"$T_OK\"}")"
assert_equals   "  ...still exactly one used row for this token"      "1" "$(sql "select count(*) from coach_magic_links where token='$T_OK' and used_at is not null")"

# ---------------------------------------------------------------------------
# 4. Expiry — a link past its window fails, and is NOT consumed
# ---------------------------------------------------------------------------
printf '\n%s-- expired link --%s\n' "$B" "$N"
T_EXP=$(new_token)
insert_link "$T_EXP" "$FARAH_ID" "$ORG_IRON" "now() - interval '1 minute'"
assert_contains "an expired link -> link_expired"        '"error":"link_expired"' "$(vml "{\"token\":\"$T_EXP\"}")"
assert_equals   "  ...410, not 200"                      "410" "$(vml_status "{\"token\":\"$T_EXP\"}")"
assert_equals   "  ...the claim did NOT stamp used_at on an expired row" "f" \
  "$(sql "select (used_at is not null) from coach_magic_links where token='$T_EXP'")"

# ---------------------------------------------------------------------------
# 5. Deactivated coach — link is claimed but no session is minted
# ---------------------------------------------------------------------------
printf '\n%s-- link for a deactivated coach --%s\n' "$B" "$N"
T_DEACT=$(new_token); T_DEACT2=$(new_token)
insert_link "$T_DEACT"  "$DEACT_COACH_ID" "$ORG_IRON" "now() + interval '15 minutes'"
insert_link "$T_DEACT2" "$DEACT_COACH_ID" "$ORG_IRON" "now() + interval '15 minutes'"
got=$(vml "{\"token\":\"$T_DEACT\"}")
assert_contains "deactivated coach -> coach_unavailable" '"error":"coach_unavailable"' "$got"
assert_equals   "  ...403, not 200"                      "403" "$(vml_status "{\"token\":\"$T_DEACT2\"}")"
assert_not_contains "  ...no session was minted"         '"access_token"' "$got"

# ---------------------------------------------------------------------------
# 6. End to end — coach texts SESSION, gets a link, redeems it once
# ---------------------------------------------------------------------------
printf '\n%s-- end to end: SESSION -> link -> redeem --%s\n' "$B" "$N"
e2e_skip=""
[ "$(printf '%s' "$WA_SEND_MODE" | tr '[:upper:]' '[:lower:]')" = "mock" ] || e2e_skip="whatsapp-webhook not in WHATSAPP_SEND_MODE=mock"
if [ -z "$e2e_skip" ] && ! curl -s -o /dev/null --max-time 5 "$WH_URL"; then e2e_skip="whatsapp-webhook not served"; fi

if [ -n "$e2e_skip" ]; then
  skipped "coach texts SESSION -> receives a magic link" "$e2e_skip"
  skipped "  ...that link redeems for a coach session"   "$e2e_skip"
  skipped "  ...and cannot be redeemed a second time"    "$e2e_skip"
else
  ENVELOPE='{"object":"whatsapp_business_account","entry":[{"id":"WABA","changes":[{"field":"messages","value":{"messaging_product":"whatsapp","metadata":{"display_phone_number":"911111111111","phone_number_id":"PID"},"messages":[{"from":"'"$FARAH_PHONE"'","id":"wamid.vml-'"$(date +%s)"'","timestamp":"1700000000","type":"text","text":{"body":"SESSION"}}]}}]}]}'
  wargs=(-s -X POST "$WH_URL" -H 'Content-Type: application/json')
  if [ -n "$APP_SECRET" ] && $have_openssl; then
    SIG=$(printf '%s' "$ENVELOPE" | openssl dgst -sha256 -hmac "$APP_SECRET" | sed 's/^.*= */sha256=/')
    wargs+=(-H "X-Hub-Signature-256: $SIG")
  fi
  wresp=$(curl "${wargs[@]}" -d "$ENVELOPE")
  assert_contains "whatsapp-webhook accepts the SESSION message" '"resolution":"coach"' "$wresp"

  LINK=$(sql "select body_preview from whatsapp_messages
              where organization_id='$ORG_IRON' and body_preview like '%coach/quick-log?token=%'
              order by created_at desc limit 1")
  E2E_TOKEN=$(printf '%s' "$LINK" | sed -n 's/.*token=\([A-Za-z0-9_-]\{32,128\}\).*/\1/p')
  if [ -z "$E2E_TOKEN" ]; then
    bad "coach texts SESSION -> receives a magic link" "a /coach/quick-log?token=… line" "$LINK"
  else
    ok "coach texts SESSION -> receives a magic link"
    row=$(sql "select (used_at is null)||'|'||(expires_at > now())::text||'|'||coach_user_id from coach_magic_links where token='$E2E_TOKEN'")
    assert_equals "  ...persisted unused, unexpired, scoped to this coach" "true|true|$FARAH_ID" "$row"
    e2e=$(vml "{\"token\":\"$E2E_TOKEN\"}")
    assert_contains "  ...that link redeems for a coach session" '"ok":true' "$e2e"
    assert_contains "  ...redeemed as this coach"                "\"organization_id\":\"$ORG_IRON\"" "$e2e"
    assert_contains "  ...and cannot be redeemed a second time"  '"error":"link_already_used"' "$(vml "{\"token\":\"$E2E_TOKEN\"}")"
  fi
fi

# ---------------------------------------------------------------------------
reset_state

printf '\n%s== summary ==%s\n' "$B" "$N"
printf '  %spassed %d%s   %sfailed %d%s   %sskipped %d%s\n' "$G" "$PASS" "$N" "$R" "$FAIL" "$N" "$Y" "$SKIP" "$N"
if [ "$FAIL" -gt 0 ]; then
  printf '\n  failing cases:\n'; for c in "${FAILED_CASES[@]}"; do printf '    - %s\n' "$c"; done
  printf '\n'; exit 1
fi
printf '\n'; exit 0
