#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Run every Edge Function test suite in one pass.
#
# Individually-green suites are not the same as collectively-green ones: these
# share one database and one seed, so a suite that fails to restore its fixtures
# shows up here and nowhere else. Order matters for exactly that reason — the
# suites that mutate the most run first, and razorpay-webhook runs last because
# its fixtures are the ones everything else borrows.
#
# PREREQUISITES
#   1. supabase start
#   2. supabase db reset
#   3. supabase functions serve --env-file supabase/functions/.env
#   4. bash supabase/functions/run-all-tests.sh
#
# NOTE: renewal-scan and send-renewal-reminder create REAL Razorpay TEST MODE
# payment links. Both refuse to run against an rzp_live_ key.
# ---------------------------------------------------------------------------

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"

SUITES=(
  whatsapp-webhook
  mark-overdue
  daily-owner-brief
  send-renewal-reminder
  renewal-scan
  razorpay-webhook
  staff-login
  staff-lookup-by-phone
  staff-pin-reset
  staff-manage
)

if [ -t 1 ]; then
  G=$'\033[32m'; R=$'\033[31m'; Y=$'\033[33m'; B=$'\033[1m'; N=$'\033[0m'
else
  G=""; R=""; Y=""; B=""; N=""
fi

declare -a NAMES=() STATUS=() COUNTS=()
FAILED=0
started=$(date +%s)

printf '\n%s=========================================%s\n' "$B" "$N"
printf '%s  full Edge Function suite%s\n' "$B" "$N"
printf '%s=========================================%s\n' "$B" "$N"

for suite in "${SUITES[@]}"; do
  script="$HERE/$suite/test.sh"

  if [ ! -f "$script" ]; then
    printf '\n%s>>> %s%s  %sNO test.sh%s\n' "$B" "$suite" "$N" "$Y" "$N"
    NAMES+=("$suite"); STATUS+=("MISSING"); COUNTS+=("-")
    continue
  fi

  printf '\n%s>>> %s%s\n' "$B" "$suite" "$N"

  out=$(bash "$script" 2>&1)
  rc=$?

  printf '%s\n' "$out"

  # Pull the "passed N failed N skipped N" line each suite prints.
  line=$(printf '%s' "$out" | sed -n 's/.*passed \([0-9]*\).*failed \([0-9]*\).*skipped \([0-9]*\).*/\1\/\2\/\3/p' | tail -1)

  NAMES+=("$suite")
  COUNTS+=("${line:--}")
  if [ "$rc" -eq 0 ]; then
    STATUS+=("PASS")
  else
    STATUS+=("FAIL")
    FAILED=$((FAILED+1))
  fi
done

elapsed=$(( $(date +%s) - started ))

printf '\n%s=========================================%s\n' "$B" "$N"
printf '%s  combined result%s\n' "$B" "$N"
printf '%s=========================================%s\n' "$B" "$N"
printf '  %-24s %-8s %s\n' "suite" "result" "pass/fail/skip"
printf '  %-24s %-8s %s\n' "------------------------" "--------" "--------------"

for i in "${!NAMES[@]}"; do
  case "${STATUS[$i]}" in
    PASS)    colour="$G" ;;
    FAIL)    colour="$R" ;;
    *)       colour="$Y" ;;
  esac
  printf '  %-24s %s%-8s%s %s\n' "${NAMES[$i]}" "$colour" "${STATUS[$i]}" "$N" "${COUNTS[$i]}"
done

printf '\n  elapsed: %dm%02ds\n' $((elapsed/60)) $((elapsed%60))

if [ "$FAILED" -gt 0 ]; then
  printf '\n  %s%d suite(s) failed%s\n\n' "$R" "$FAILED" "$N"
  exit 1
fi

printf '\n  %sall suites green%s\n\n' "$G" "$N"
exit 0
