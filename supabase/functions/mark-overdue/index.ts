// mark-overdue — advance lapsed memberships from 'active' to 'past_due', AND
// auto-unfreeze memberships whose freeze has run its course.
//
// POST {}                  -> transition every lapsed membership, auto-unfreeze
// POST { "dry_run": true } -> report what would happen, write nothing
//
// Runs daily at 06:45 IST via pg_cron, fifteen minutes AHEAD of renewal-scan
// and daily-owner-brief, so both of those read a status column that is already
// current for the day.
//
// ============================================================================
// AUTO-UNFREEZE (20260904090000_membership_freezing.sql) — WHY IT LIVES HERE
// ============================================================================
// Same shape of problem this whole function already exists to solve: a
// membership can end up in a status that only a scheduled sweep can correct,
// because nothing else runs every day. 'frozen' is reached through
// freeze_membership() (an owner/front_desk RPC) and left through EITHER
// unfreeze_membership() (a manual early end, any day) OR — the case nothing
// else drives — simply letting the requested freeze run out. This function is
// that second path's writer, added as a THIRD zone-scoped pass rather than a
// new sibling function, because it needs the exact same per-org-timezone
// "today" this file already computes, and because the ordering below is load
// bearing, not incidental:
//
//   for each zone group:
//     1. auto-unfreeze  (frozen_until <= today)   <- NEW, runs FIRST
//     2. overdue scan   (status='active' AND current_period_end < today)
//
// Unfreezing first, in the SAME run, matters for a real case: a membership
// can only be frozen while 'active' (freeze_membership() requires it), but
// 'active' does not mean "not yet due" — a membership can legitimately be
// frozen on the very day it would otherwise have been caught by THIS
// function's overdue scan (frozen before that day's mark-overdue run got to
// it). Auto-unfreeze shifts current_period_end forward by the freeze's
// `days`, which moves it later but does not guarantee it lands in the
// future — a membership frozen while already significantly lapsed, for a
// freeze shorter than the lapse, unfreezes still overdue. Running the scan
// AFTER unfreeze in the same invocation catches that immediately; reversing
// the order would leave it silently 'active' with a stale date for a full
// extra day, exactly the bug this function exists to prevent for the
// non-freeze case.
//
// Neither pass needed to change to skip the other's status: renewal-scan's
// SCAN_STATUSES and this function's overdue scan both already WHITELIST
// ('active','past_due' / 'active' respectively) rather than blacklist, so
// 'frozen' — a status neither list names — was excluded from both the moment
// it became a legal value. Nothing to skip; there is nothing there to match.
// ============================================================================
//
// ============================================================================
// WHY THIS FUNCTION EXISTS AT ALL
// ============================================================================
// memberships.status has had a 'past_due' value in its CHECK constraint since
// the first migration, and until now NOTHING EVER WROTE IT:
//
//   - razorpay-webhook sets 'active' on a successful payment, and on
//     payment.failed deliberately leaves status alone — "deciding when to move
//     a membership to past_due/expired is a dunning policy, and belongs in the
//     scheduled reminder job, not in a payment callback."
//     (razorpay-webhook/index.ts:553-557)
//   - renewal-scan, the scheduled reminder job, is read-only by design.
//   - send-renewal-reminder, daily-owner-brief and whatsapp-webhook only read it.
//
// So in production every lapsed membership sat at 'active' with a
// current_period_end in the past, forever. Two visible consequences:
// daily-owner-brief's Overdue section could only ever report zero, and
// renewal-scan's dunning offsets (-3, -7) could never match anything, because
// past_due is a precondition of its query.
//
// This function is the missing writer. It is DELIBERATELY SEPARATE from
// renewal-scan: a status transition and a member-facing message are different
// concerns, and a bug in one must not be able to corrupt the other. This
// function sends nothing and holds no messaging grants; renewal-scan writes
// nothing and holds no UPDATE grant on memberships.
//
// ============================================================================
// WHAT THIS FUNCTION DOES NOT DO
// ============================================================================
// It never moves a membership OUT of 'past_due'. That direction is already
// handled, and handled better, by razorpay-webhook: on payment success it sets
// `{ status: 'active', current_period_end: <extended> }` unconditionally,
// without reading the prior status, so a past_due membership that gets paid
// flips straight back to active. Verified by reading that code path, and
// covered end-to-end by a real signed webhook in this function's test.sh.
//
// It also never sets 'expired' or 'cancelled'. Those are end-states with real
// consequences for a member's access, and deciding when a lapsed member has
// lapsed *for good* is a business policy nobody has written down yet. Guessing
// at it here would be the same mistake that left past_due unwritten.
// ============================================================================

import "@supabase/functions-js/edge-runtime.d.ts";
import { createAdminClient, type SupabaseClient } from "../_shared/supabase.ts";
import { authorizeServiceRole } from "../_shared/auth.ts";
import { ACTIVE_ORG_STATUSES } from "../_shared/org-status.ts";

const TAG = "mark-overdue";

const FROM_STATUS = "active" as const;
const TO_STATUS = "past_due" as const;

// Auto-unfreeze: a membership whose freeze has run its course goes back to
// 'active', with current_period_end shifted forward. See the header note
// above the unfreeze functions below for the full mechanic and why this
// runs BEFORE the overdue scan in every zone.
const FROZEN_STATUS = "frozen" as const;
const UNFROZEN_STATUS = "active" as const;

// Fallback when an organization has no locations row to read a timezone from.
const DEFAULT_TIMEZONE = Deno.env.get("BILLING_TIMEZONE") ?? "Asia/Kolkata";

// PostgREST puts `.in()` lists in the query string, so an unbounded IN clause
// eventually produces a URL the gateway rejects. Chunked well below that.
const UPDATE_CHUNK = 200;

// Cap on one run, same reasoning as the other scheduled functions: a run that
// trips the hosted wall-clock ceiling dies with no summary at all.
const DEFAULT_LIMIT = 5000;
const MAX_LIMIT = 50_000;

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

interface LapsedRow {
  id: string;
  organization_id: string;
  member_id: string;
  current_period_end: string;
}

interface ZoneGroup {
  timezone: string;
  today: string;
  organization_ids: string[];
}

interface TransitionedRow {
  membership_id: string;
  organization_id: string;
  member_id: string;
  current_period_end: string;
  days_overdue: number;
  timezone: string;
}

interface FrozenMembershipRow {
  id: string;
  organization_id: string;
  member_id: string;
  current_period_end: string;
}

/** The membership_freezes row governing one currently-frozen membership. */
interface GoverningFreeze {
  id: string;
  membership_id: string;
  days: number;
  frozen_until: string;
}

interface UnfrozenRow {
  membership_id: string;
  organization_id: string;
  member_id: string;
  freeze_id: string;
  days: number;
  previous_current_period_end: string;
  new_current_period_end: string;
  timezone: string;
}

// ---------------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------------

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

/** Today as YYYY-MM-DD in `timeZone`. en-CA formats as ISO. */
function localDate(timeZone: string, at = new Date()): string {
  return new Intl.DateTimeFormat("en-CA", {
    timeZone,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).format(at);
}

/** Whole days from `from` to `to`, both YYYY-MM-DD. */
function daysBetween(from: string, to: string): number {
  const [fy, fm, fd] = from.split("-").map(Number);
  const [ty, tm, td] = to.split("-").map(Number);
  return Math.round(
    (Date.UTC(ty, tm - 1, td) - Date.UTC(fy, fm - 1, fd)) / 86_400_000,
  );
}

/** Add whole days to a YYYY-MM-DD string. Pure calendar arithmetic, no zone. */
function addDays(isoDate: string, days: number): string {
  const [y, m, d] = isoDate.split("-").map(Number);
  return new Date(Date.UTC(y, m - 1, d + days)).toISOString().slice(0, 10);
}

function chunk<T>(items: T[], size: number): T[][] {
  const out: T[][] = [];
  for (let i = 0; i < items.length; i += size) out.push(items.slice(i, i + size));
  return out;
}

// ---------------------------------------------------------------------------
// Tenant timezones
// ---------------------------------------------------------------------------

/**
 * Group every organization by the timezone its calendar day should be read in.
 *
 * Consistent with daily-owner-brief: the zone comes from the organization's
 * OLDEST location, because there is no "primary location" column to consult and
 * the oldest is a stable, explainable choice. Orgs with no location fall back to
 * BILLING_TIMEZONE.
 *
 * WHY THIS MATTERS HERE. current_period_end is a DATE. A membership ending
 * 2026-08-23 is not overdue until 2026-08-24 has begun *for that gym*. Between
 * 00:00 and 05:30 IST the UTC date is already tomorrow while the gym's is not,
 * so a naive `current_period_end < CURRENT_DATE` in UTC would mark a member
 * past_due up to five and a half hours early — on the very morning their
 * renewal reminder is due to go out, and while they can still walk in and pay.
 *
 * NOTE ON ORG STATUS: like renewal-scan and daily-owner-brief, this now skips
 * suspended organizations — a frozen tenant's data is frozen, full stop. It is
 * safe to skip here because mark-overdue is idempotent: the first run after an
 * org is reactivated transitions every membership whose current_period_end
 * passed during the suspension, catching the whole backlog up in one pass.
 */
async function loadZoneGroups(supabase: SupabaseClient): Promise<ZoneGroup[]> {
  const { data: orgs, error: orgError } = await supabase
    .from("organizations")
    .select("id")
    .in("status", ACTIVE_ORG_STATUSES as unknown as string[])
    .order("id", { ascending: true });

  if (orgError) throw orgError;

  const orgIds = (orgs ?? []).map((o) => o.id as string);
  if (orgIds.length === 0) return [];

  const { data: locs, error: locError } = await supabase
    .from("locations")
    .select("organization_id,timezone,created_at")
    .in("organization_id", orgIds)
    .order("created_at", { ascending: true });

  if (locError) throw locError;

  const zoneOf = new Map<string, string>();
  for (const row of locs ?? []) {
    // First row per org wins — the list is ordered oldest-first.
    if (!zoneOf.has(row.organization_id) && row.timezone) {
      zoneOf.set(row.organization_id, row.timezone);
    }
  }

  const byZone = new Map<string, string[]>();
  for (const id of orgIds) {
    const tz = zoneOf.get(id) ?? DEFAULT_TIMEZONE;
    const list = byZone.get(tz);
    if (list) list.push(id);
    else byZone.set(tz, [id]);
  }

  return [...byZone.entries()]
    .map(([timezone, organization_ids]) => ({
      timezone,
      today: localDate(timezone),
      organization_ids,
    }))
    .sort((a, b) => a.timezone.localeCompare(b.timezone));
}

// ---------------------------------------------------------------------------
// Auto-unfreeze — see the header note above for why this runs first
// ---------------------------------------------------------------------------

/**
 * Frozen memberships whose freeze has run its course (frozen_until <= today),
 * for one zone group, each paired with its governing membership_freezes row.
 *
 * "Governing" = the most recent membership_freezes row for that membership_id.
 * freeze_membership() requires status='active' as a precondition, so a
 * membership can only be inside ONE frozen episode at a time — its newest
 * freeze row IS that episode, regardless of how many older, already-resolved
 * freeze/unfreeze cycles sit behind it. Fetched in two round trips rather
 * than a single embedded query because PostgREST cannot express "only the
 * latest row per membership_id" — filtering to the first occurrence per
 * membership_id happens here, in JS, over a freeze-row list ordered newest
 * first. A membership found 'frozen' with NO freeze row at all is a data
 * inconsistency (unreachable via freeze_membership()/unfreeze_membership(),
 * both of which keep the two tables in lockstep) — logged and skipped rather
 * than thrown, so one bad row cannot cost the whole zone its run.
 */
async function selectFrozenDue(
  supabase: SupabaseClient,
  group: ZoneGroup,
  limit: number,
): Promise<{ membership: FrozenMembershipRow; freeze: GoverningFreeze }[]> {
  const { data: frozenData, error: frozenError } = await supabase
    .from("memberships")
    .select("id,organization_id,member_id,current_period_end")
    .in("organization_id", group.organization_ids)
    .eq("status", FROZEN_STATUS)
    .order("id", { ascending: true }) // stable tiebreak, matches selectLapsed
    .limit(limit);

  if (frozenError) throw frozenError;

  const frozen = (frozenData ?? []) as FrozenMembershipRow[];
  if (frozen.length === 0) return [];

  const { data: freezeData, error: freezeError } = await supabase
    .from("membership_freezes")
    .select("id,membership_id,days,frozen_until")
    .in("membership_id", frozen.map((m) => m.id))
    .order("created_at", { ascending: false });

  if (freezeError) throw freezeError;

  const governing = new Map<string, GoverningFreeze>();
  for (const f of (freezeData ?? []) as GoverningFreeze[]) {
    if (!governing.has(f.membership_id)) governing.set(f.membership_id, f);
  }

  const due: { membership: FrozenMembershipRow; freeze: GoverningFreeze }[] = [];
  for (const membership of frozen) {
    const freeze = governing.get(membership.id);
    if (!freeze) {
      console.error(
        `[${TAG}] membership ${membership.id} is '${FROZEN_STATUS}' with no ` +
          "membership_freezes row — data inconsistency, skipped.",
      );
      continue;
    }
    if (freeze.frozen_until <= group.today) due.push({ membership, freeze });
  }
  return due;
}

/**
 * Auto-unfreeze a batch: current_period_end += the freeze's ORIGINAL `days`
 * (not elapsed calendar time — see the header note above), status -> 'active'.
 *
 * Compare-and-set on the write (`.eq("status", FROZEN_STATUS)`), same
 * discipline as transition() below: a membership someone manually unfroze via
 * unfreeze_membership() between selection and this write is left alone rather
 * than double-credited days. reactivated_at on membership_freezes is
 * deliberately NOT set here — see the migration header for why NULL there
 * does not mean "still frozen".
 */
async function autoUnfreeze(
  supabase: SupabaseClient,
  items: { membership: FrozenMembershipRow; freeze: GoverningFreeze }[],
  timezone: string,
): Promise<UnfrozenRow[]> {
  const out: UnfrozenRow[] = [];

  for (const { membership, freeze } of items) {
    const newEnd = addDays(membership.current_period_end, freeze.days);

    const { data, error } = await supabase
      .from("memberships")
      .update({ status: UNFROZEN_STATUS, current_period_end: newEnd })
      .eq("id", membership.id)
      .eq("status", FROZEN_STATUS)
      .select("id")
      .maybeSingle();

    if (error) throw error;
    if (!data) continue; // raced — no longer frozen at write time, left alone

    out.push({
      membership_id: membership.id,
      organization_id: membership.organization_id,
      member_id: membership.member_id,
      freeze_id: freeze.id,
      days: freeze.days,
      previous_current_period_end: membership.current_period_end,
      new_current_period_end: newEnd,
      timezone,
    });
  }

  return out;
}

// ---------------------------------------------------------------------------
// Selection and transition
// ---------------------------------------------------------------------------

/**
 * Memberships that have lapsed but are still marked active, for one zone group.
 *
 * `.lt("current_period_end", today)` is a STRICT less-than, which is the whole
 * boundary rule: a membership ending TODAY is still valid all day and must not
 * be touched. Only one ending yesterday or earlier is overdue. The test suite
 * pins both sides of that boundary.
 *
 * Uses idx_memberships_due (organization_id, status, current_period_end).
 */
async function selectLapsed(
  supabase: SupabaseClient,
  group: ZoneGroup,
  limit: number,
): Promise<LapsedRow[]> {
  const { data, error } = await supabase
    .from("memberships")
    .select("id,organization_id,member_id,current_period_end")
    .in("organization_id", group.organization_ids)
    .eq("status", FROM_STATUS)
    .lt("current_period_end", group.today)
    .order("current_period_end", { ascending: true })
    .order("id", { ascending: true }) // stable tiebreak, so runs are reproducible
    .limit(limit);

  if (error) throw error;

  return (data ?? []) as LapsedRow[];
}

/**
 * Flip a batch of memberships to past_due, returning the ids that ACTUALLY
 * changed.
 *
 * The two filters repeated on the UPDATE are not redundant with the SELECT —
 * they make this a compare-and-set. razorpay-webhook can set a membership back
 * to `{status:'active', current_period_end:<extended>}` at any moment, including
 * between our SELECT and our UPDATE. Without `.eq("status", FROM_STATUS)` and
 * `.lt("current_period_end", today)` on the write, a member who paid during the
 * run would be silently marked past_due immediately after their payment landed —
 * a wrong state that nothing else would ever correct, on the one member who did
 * everything right.
 *
 * Because the write re-checks, the returned rows are the true transition set:
 * anything that slipped away in between simply is not in the result.
 */
async function transition(
  supabase: SupabaseClient,
  ids: string[],
  today: string,
): Promise<string[]> {
  const changed: string[] = [];

  for (const batch of chunk(ids, UPDATE_CHUNK)) {
    const { data, error } = await supabase
      .from("memberships")
      .update({ status: TO_STATUS })
      .in("id", batch)
      .eq("status", FROM_STATUS)
      .lt("current_period_end", today)
      .select("id");

    if (error) throw error;

    for (const row of data ?? []) changed.push(row.id as string);
  }

  return changed;
}

// ---------------------------------------------------------------------------
// Main flow
// ---------------------------------------------------------------------------

async function handleMarkOverdue(req: Request): Promise<Response> {
  const startedAt = Date.now();

  // --- Input. A cron trigger may send no body, an empty body, or `{}` ---
  let body: Record<string, unknown> = {};
  const raw = await req.text().catch(() => "");

  if (raw.trim()) {
    try {
      const parsed = JSON.parse(raw);
      if (parsed !== null && typeof parsed === "object" && !Array.isArray(parsed)) {
        body = parsed as Record<string, unknown>;
      } else {
        return json({ ok: false, error: "body_must_be_object" }, 400);
      }
    } catch {
      return json({ ok: false, error: "invalid_json_body" }, 400);
    }
  }

  // Strict boolean. This function WRITES, so a dry run being silently
  // downgraded into a real run is the expensive direction of that mistake.
  const dryRunRaw = body.dry_run;
  if (dryRunRaw !== undefined && typeof dryRunRaw !== "boolean") {
    return json({
      ok: false,
      error: "dry_run_must_be_boolean",
      detail: `got ${JSON.stringify(dryRunRaw)}`,
    }, 400);
  }
  const dryRun = dryRunRaw === true;

  let limit = DEFAULT_LIMIT;
  if (body.limit !== undefined) {
    const n = Number(body.limit);
    if (!Number.isInteger(n) || n < 1 || n > MAX_LIMIT) {
      return json({
        ok: false,
        error: "limit_invalid",
        detail: `expected an integer 1..${MAX_LIMIT}`,
      }, 400);
    }
    limit = n;
  }

  const supabase = createAdminClient();
  const groups = await loadZoneGroups(supabase);

  const scanned: TransitionedRow[] = [];
  const transitioned: TransitionedRow[] = [];
  const frozenDue: UnfrozenRow[] = [];
  const unfrozen: UnfrozenRow[] = [];
  const errors: { timezone: string; error: string; detail?: string }[] = [];

  let remaining = limit;

  for (const group of groups) {
    if (remaining <= 0) break;

    try {
      // --- (1) Auto-unfreeze FIRST — see the header note on why the order
      // --- within one zone (and one run) matters. ---
      const due = await selectFrozenDue(supabase, group, remaining);
      remaining -= due.length;

      const describeUnfreeze = (
        item: { membership: FrozenMembershipRow; freeze: GoverningFreeze },
      ): UnfrozenRow => ({
        membership_id: item.membership.id,
        organization_id: item.membership.organization_id,
        member_id: item.membership.member_id,
        freeze_id: item.freeze.id,
        days: item.freeze.days,
        previous_current_period_end: item.membership.current_period_end,
        new_current_period_end: addDays(item.membership.current_period_end, item.freeze.days),
        timezone: group.timezone,
      });

      for (const item of due) frozenDue.push(describeUnfreeze(item));

      if (!dryRun && due.length > 0) {
        unfrozen.push(...await autoUnfreeze(supabase, due, group.timezone));
      }

      if (remaining <= 0) continue;

      // --- (2) THEN the existing overdue scan, unchanged. ---
      const lapsed = await selectLapsed(supabase, group, remaining);
      remaining -= lapsed.length;

      const describe = (row: LapsedRow): TransitionedRow => ({
        membership_id: row.id,
        organization_id: row.organization_id,
        member_id: row.member_id,
        current_period_end: row.current_period_end,
        days_overdue: daysBetween(row.current_period_end, group.today),
        timezone: group.timezone,
      });

      for (const row of lapsed) scanned.push(describe(row));

      if (dryRun || lapsed.length === 0) continue;

      const changedIds = new Set(
        await transition(supabase, lapsed.map((r) => r.id), group.today),
      );

      for (const row of lapsed) {
        if (changedIds.has(row.id)) transitioned.push(describe(row));
      }

      // A row that was selected but did not change means someone paid mid-run.
      // That is a correct outcome, not an error — worth one log line, not an
      // alert.
      const raced = lapsed.length - changedIds.size;
      if (raced > 0) {
        console.log(
          `[${TAG}] ${raced} membership(s) in ${group.timezone} were no longer ` +
            "eligible at write time (paid mid-run) — left alone.",
        );
      }
    } catch (err) {
      // (6-style resilience) One timezone group's failure must not cost every
      // other tenant their transition.
      const detail = err instanceof Error ? err.message : String(err);
      console.error(`[${TAG}] zone ${group.timezone} failed:`, detail);
      errors.push({ timezone: group.timezone, error: "zone_failed", detail });
    }
  }

  // Shared `remaining` budget spans BOTH passes now, so truncation must look
  // at both totals, not just the overdue scan's.
  const truncated = remaining <= 0 && (scanned.length + frozenDue.length) >= limit;

  const summary = {
    ok: true,
    dry_run: dryRun,
    from_status: FROM_STATUS,
    to_status: TO_STATUS,
    frozen_status: FROZEN_STATUS,
    unfrozen_status: UNFROZEN_STATUS,
    zones: groups.map((g) => ({
      timezone: g.timezone,
      today: g.today,
      organization_count: g.organization_ids.length,
    })),
    // In a dry run these are the rows that WOULD transition; in a real run,
    // the rows that were eligible when selected.
    eligible: scanned.length,
    frozen_due: frozenDue.length,
    // Named distinctly from `eligible`/`frozen_due` so a dry-run summary can
    // never be mistaken for evidence that rows were written.
    ...(dryRun
      ? {
        would_transition: scanned.length,
        would_transition_membership_ids: scanned.map((r) => r.membership_id),
        would_unfreeze: frozenDue.length,
        would_unfreeze_membership_ids: frozenDue.map((r) => r.membership_id),
      }
      : {
        transitioned: transitioned.length,
        transitioned_membership_ids: transitioned.map((r) => r.membership_id),
        unfrozen: unfrozen.length,
        unfrozen_membership_ids: unfrozen.map((r) => r.membership_id),
      }),
    truncated,
    limit,
    errored: errors.length,
    errors,
    results: dryRun ? scanned : transitioned,
    unfreeze_results: dryRun ? frozenDue : unfrozen,
    duration_ms: Date.now() - startedAt,
  };

  console.log(
    `[${TAG}] ${dryRun ? "DRY RUN" : "done"}: ${scanned.length} eligible, ` +
      `${dryRun ? 0 : transitioned.length} transitioned, ` +
      `${frozenDue.length} frozen due, ${dryRun ? 0 : unfrozen.length} auto-unfrozen, ` +
      `${errors.length} zone error(s) in ${summary.duration_ms}ms`,
  );

  for (const row of unfrozen) {
    console.log(
      `[${TAG}] auto-unfroze membership ${row.membership_id} (org ${row.organization_id}): ` +
        `freeze ${row.freeze_id}, +${row.days}d, current_period_end ` +
        `${row.previous_current_period_end} -> ${row.new_current_period_end}.`,
    );
  }

  if (truncated) {
    console.warn(
      `[${TAG}] hit limit=${limit}. Tomorrow's run WILL pick up the remainder ` +
        "(they stay lapsed and still-active), but re-run now if the backlog matters.",
    );
  }

  return json(summary);
}

// ---------------------------------------------------------------------------
// Entrypoint
// ---------------------------------------------------------------------------

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") {
    return json({ error: "method_not_allowed" }, 405);
  }

  const verdict = authorizeServiceRole(req, TAG);
  if (verdict === "misconfigured") {
    return json({ ok: false, error: "service_role_key_not_configured" }, 500);
  }
  if (verdict === "unauthorized") {
    console.warn(`[${TAG}] rejected: caller did not present the service role key`);
    return json({ ok: false, error: "unauthorized" }, 401);
  }

  try {
    return await handleMarkOverdue(req);
  } catch (err) {
    // A 5xx here means the RUN broke (the organizations/locations query failed),
    // not that one zone did — those are collected into `errors` and still 200.
    console.error(`[${TAG}] unhandled failure:`, err);
    return json({
      ok: false,
      error: "internal_error",
      detail: err instanceof Error ? err.message : String(err),
    }, 500);
  }
});
