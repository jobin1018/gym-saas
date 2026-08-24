// daily-owner-brief — one WhatsApp summary per gym owner, every morning.
//
// POST {}                                          -> brief every active/trial org
// POST { "organization_id": "<uuid>" }             -> brief just that org
// POST { "dry_run": true, "organization_id": ... } -> compute and return, send nothing
// POST { "dry_run": true }                         -> compute every org, send nothing
//
// Triggered daily by pg_cron (see the cron migration), and directly by curl for
// testing.
//
// ============================================================================
// WHAT IS REAL
// ============================================================================
// REAL: every number in the brief. They are computed from memberships,
//       payments, attendance and whatsapp_messages at request time.
//
// REAL: the outbound send, via the shared helper in ../_shared/whatsapp.ts —
//       a real call to Meta's Cloud API. It goes out as free-form "type":
//       "text", not an approved template (see the TODO(meta) in
//       ../_shared/whatsapp.ts for why, and what to change once a template is
//       approved). WHATSAPP_SEND_MODE=mock skips the real call; this
//       function's test.sh enforces that for automated runs.
//
// ============================================================================
// THE RECIPIENT IS AN ORGANIZATION, NOT A MEMBER
// ============================================================================
// Every other outbound message in this system goes to a member. This one goes
// to organizations.owner_phone, so the whatsapp_messages row it writes has
// member_id = NULL. That is allowed (the column has no NOT NULL constraint) and
// it does not disturb anything downstream:
//
//   - send-renewal-reminder's once-per-day guard filters on
//     .eq("member_id", <uuid>), which a NULL row can never match.
//   - It is the only other reader of whatsapp_messages in the codebase.
//   - idx_wa_msgs_member is a btree, which indexes NULLs fine.
//
// This function's own dedup guard keys on organization_id + template_name
// instead of member_id, for the same reason.
// ============================================================================

import "@supabase/functions-js/edge-runtime.d.ts";
import { createAdminClient, type SupabaseClient } from "../_shared/supabase.ts";
import { authorizeServiceRole } from "../_shared/auth.ts";
import { sendWhatsAppMessage } from "../_shared/whatsapp.ts";

const TAG = "daily-owner-brief";
const TEMPLATE_NAME = "daily_owner_brief" as const;

// Orgs that get a brief. 'suspended' is excluded: a suspended account should not
// be receiving daily operational messages.
const BRIEF_ORG_STATUSES = ["active", "trial"] as const;

// Memberships still on the hook for money. See the long note on OVERDUE below
// for why 'active' is in this list and not just 'past_due'.
const OWING_STATUSES = ["active", "past_due"] as const;

// How far ahead "due this week" looks.
const DUE_WINDOW_DAYS = 7;

// Fallback when an organization has no locations row to read a timezone from.
const DEFAULT_TIMEZONE = Deno.env.get("BILLING_TIMEZONE") ?? "Asia/Kolkata";

// ---------------------------------------------------------------------------
// DETECTING FAILED SENDS — why the obvious rule is currently the wrong one
// ---------------------------------------------------------------------------
// The brief for this function proposed: status='failed' OR (status='queued' AND
// older than ~2 hours). The second half of that would be actively harmful right
// now, and it is worth being precise about why.
//
// ../_shared/whatsapp.ts inserts every outbound row with status 'queued' and
// NOTHING ever advances it. The Meta delivery-status consumer does not exist —
// whatsapp-webhook/index.ts:510 still carries
//   "TODO(meta): consume `value.statuses` to advance whatsapp_messages.status"
// so 'sent' and 'delivered' are unreachable states for outbound messages today.
//
// A "queued for more than 2 hours means it never went out" rule would therefore
// match EVERY outbound message the system has ever written, and the owner's
// brief would report a large failure count every single morning. A metric that
// is always wrong in the same direction is worse than no metric: people learn
// to ignore the line, and then miss the day it is real.
//
// So the stale-queued heuristic is gated on delivery tracking actually being
// live. While it is simulated, "failed" means exactly status='failed' — which
// is 0, and 0 is the truthful answer, because nothing is being sent and so
// nothing can fail to send.
//
// Flip this the day the real Cloud API lands, together with the TODO(meta) in
// ../_shared/whatsapp.ts:
//   supabase secrets set WHATSAPP_DELIVERY_TRACKING=live
const DELIVERY_TRACKING = Deno.env.get("WHATSAPP_DELIVERY_TRACKING") ?? "simulated";
const STALE_QUEUED_MINUTES = Number(
  Deno.env.get("WHATSAPP_STALE_QUEUED_MINUTES") ?? "120",
);
const FAILED_LOOKBACK_HOURS = 24;

// Cap on one run's batch, same reasoning as renewal-scan: a run that trips the
// hosted wall-clock ceiling dies with no summary at all.
const DEFAULT_LIMIT = 200;
const MAX_LIMIT = 2000;

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

interface OrgRow {
  id: string;
  name: string;
  owner_phone: string | null;
  status: string;
}

interface MembershipDueRow {
  id: string;
  current_period_end: string;
  status: string;
  membership_plans: { amount: number | string } | null;
}

interface BriefStats {
  renewals_due_count: number;
  renewals_due_amount: number;
  overdue_count: number;
  overdue_amount: number;
  checkins_yesterday: number;
  failed_sends: number;
}

interface OrgResult {
  organization_id: string;
  organization_name: string;
  outcome: "sent" | "skipped" | "error" | "computed";
  reason?: string;
  error?: string;
  detail?: string;
  timezone?: string;
  stats?: BriefStats;
  message?: string;
  whatsapp_message_id?: string | null;
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

/** The UTC offset of `timeZone` at instant `date`, in milliseconds. */
function tzOffsetMs(date: Date, timeZone: string): number {
  const parts = new Intl.DateTimeFormat("en-CA", {
    timeZone,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
    hourCycle: "h23",
  }).formatToParts(date);

  const g = (t: string) => Number(parts.find((p) => p.type === t)!.value);

  return Date.UTC(g("year"), g("month") - 1, g("day"), g("hour"), g("minute"), g("second")) -
    date.getTime();
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

/** Add whole days to a YYYY-MM-DD string. Pure calendar arithmetic, no zone. */
function addDays(isoDate: string, days: number): string {
  const [y, m, d] = isoDate.split("-").map(Number);
  return new Date(Date.UTC(y, m - 1, d + days)).toISOString().slice(0, 10);
}

/**
 * The UTC instant of local midnight starting `isoDate` in `timeZone`.
 *
 * Two passes on purpose. The first guess uses the offset in force at the
 * *UTC* interpretation of that wall time, which is wrong by up to an hour on a
 * DST transition day; re-reading the offset at the corrected instant fixes it.
 * IST has no DST, but a scan is not the place to bake in that assumption — this
 * has to keep working for the first tenant in a zone that does.
 */
function zonedMidnightUtc(isoDate: string, timeZone: string): Date {
  const [y, m, d] = isoDate.split("-").map(Number);
  const wallAsUtc = Date.UTC(y, m - 1, d);

  const first = wallAsUtc - tzOffsetMs(new Date(wallAsUtc), timeZone);
  const second = wallAsUtc - tzOffsetMs(new Date(first), timeZone);

  return new Date(second);
}

/** "23 Aug 2026" — the same member-facing date format the other functions use. */
function formatDateForOwner(isoDate: string): string {
  const [y, m, d] = isoDate.split("-").map(Number);
  return new Intl.DateTimeFormat("en-IN", {
    day: "numeric",
    month: "short",
    year: "numeric",
    timeZone: "UTC",
  }).format(new Date(Date.UTC(y, m - 1, d)));
}

/**
 * Indian-grouped rupees: 150000 -> "1,50,000". Decimals only when the amount
 * actually has paise, so the common whole-rupee case stays short — this is a
 * lock-screen preview, not a ledger.
 */
function formatRupees(amount: number): string {
  const whole = Number.isInteger(amount);
  return new Intl.NumberFormat("en-IN", {
    minimumFractionDigits: whole ? 0 : 2,
    maximumFractionDigits: whole ? 0 : 2,
  }).format(amount);
}

function plural(n: number, one: string, many: string): string {
  return n === 1 ? one : many;
}

const toAmount = (v: number | string | null | undefined): number => {
  const n = Number(v);
  return Number.isFinite(n) ? n : 0;
};

// ---------------------------------------------------------------------------
// The message
// ---------------------------------------------------------------------------

/**
 * Build the brief.
 *
 * Deviation from the spec'd format, flagged deliberately: the zero cases read
 * as words ("none", "no check-ins") rather than "0 (₹0)". Same lines, same
 * order, same emoji — but an owner whose quiet Tuesday renders as
 * "Renewals due this week: 0 (₹0)" is reading punctuation instead of news.
 * Change the three `=== 0` branches below to go back to the literal format.
 *
 * The ❌ line is omitted entirely when nothing failed, exactly as specified.
 */
function buildBrief(orgName: string, todayLocal: string, s: BriefStats): string {
  const lines: string[] = [
    `Good morning! ${orgName} — ${formatDateForOwner(todayLocal)}`,
    "",
    s.renewals_due_count === 0
      ? "💰 Renewals due this week: none"
      : `💰 Renewals due this week: ${s.renewals_due_count} (₹${
        formatRupees(s.renewals_due_amount)
      })`,
    s.overdue_count === 0
      ? "⚠️ Overdue: none"
      : `⚠️ Overdue: ${s.overdue_count} ${
        plural(s.overdue_count, "member", "members")
      }, ₹${formatRupees(s.overdue_amount)} pending`,
    "",
    s.checkins_yesterday === 0
      ? "✅ Yesterday: no check-ins"
      : `✅ Yesterday: ${s.checkins_yesterday} ${
        plural(s.checkins_yesterday, "check-in", "check-ins")
      }`,
  ];

  if (s.failed_sends > 0) {
    lines.push(
      `❌ ${s.failed_sends} ${
        plural(s.failed_sends, "message", "messages")
      } failed to send — tap to review`,
    );
  }

  return lines.join("\n");
}

// ---------------------------------------------------------------------------
// Per-organization data
// ---------------------------------------------------------------------------

/**
 * Timezone for an organization, taken from its oldest location.
 *
 * An org can have several locations in different zones; there is no
 * "primary location" column to consult, so the oldest is used as a stable,
 * explainable choice rather than whichever row the planner happened to return.
 * Single-location gyms — every tenant today — are unaffected.
 */
async function loadTimezones(
  supabase: SupabaseClient,
  orgIds: string[],
): Promise<Map<string, string>> {
  const { data, error } = await supabase
    .from("locations")
    .select("organization_id,timezone,created_at")
    .in("organization_id", orgIds)
    .order("created_at", { ascending: true });

  if (error) throw error;

  const out = new Map<string, string>();
  for (const row of data ?? []) {
    // First row per org wins — the list is ordered oldest-first.
    if (!out.has(row.organization_id) && row.timezone) {
      out.set(row.organization_id, row.timezone);
    }
  }
  return out;
}

/**
 * Renewals due this week and overdue, in one query.
 *
 * Both buckets are "memberships that still owe money, ending on or before
 * today + 7", so they come back together and are partitioned in memory. Uses
 * idx_memberships_due (organization_id, status, current_period_end).
 *
 * -------------------------------------------------------------------------
 * WHAT "OVERDUE" ACTUALLY MEANS HERE — this differs from the brief, on purpose
 * -------------------------------------------------------------------------
 * The spec said overdue = `current_period_end < today AND status = 'past_due'`,
 * and asked me to check the real state transitions rather than assume. I did,
 * and NOTHING IN THIS CODEBASE EVER SETS status = 'past_due':
 *
 *   - razorpay-webhook sets 'active' on a successful payment, and on
 *     payment.failed deliberately leaves membership status alone:
 *       "deciding when to move a membership to past_due/expired is a dunning
 *        policy, and belongs in the scheduled reminder job, not in a payment
 *        callback"                        (razorpay-webhook/index.ts:553-557)
 *   - renewal-scan, the scheduled reminder job, is read-only by design and
 *     never writes memberships.
 *   - send-renewal-reminder and whatsapp-webhook only read the column.
 *
 * So 'past_due' is currently reachable only because seed.sql hardcodes it. In
 * production every lapsed membership sits at status='active' with a
 * current_period_end in the past, forever. Filtering overdue on
 * status='past_due' would have reported 0 overdue members to every owner, every
 * day, while their gym filled up with people who had stopped paying — a wrong
 * number that looks like good news, which is the worst kind.
 *
 * The overdue signal used instead is the one that is actually maintained:
 *   current_period_end < today AND status IN ('active','past_due')
 * 'expired' and 'cancelled' are excluded — those are deliberate end-states, not
 * unpaid ones. This stays correct if the missing past_due transition is
 * implemented later, because past_due is already in the list.
 */
async function loadDueAndOverdue(
  supabase: SupabaseClient,
  orgId: string,
  todayLocal: string,
): Promise<{ due: MembershipDueRow[]; overdue: MembershipDueRow[] }> {
  const horizon = addDays(todayLocal, DUE_WINDOW_DAYS);

  const { data, error } = await supabase
    .from("memberships")
    .select("id,current_period_end,status,membership_plans(amount)")
    .eq("organization_id", orgId)
    .in("status", OWING_STATUSES as unknown as string[])
    .lte("current_period_end", horizon);

  if (error) throw error;

  const rows = (data ?? []) as MembershipDueRow[];
  const due: MembershipDueRow[] = [];
  const overdue: MembershipDueRow[] = [];

  for (const row of rows) {
    // String comparison is safe and exact for zero-padded ISO dates.
    if (row.current_period_end < todayLocal) overdue.push(row);
    else due.push(row);
  }

  return { due, overdue };
}

/** Check-ins during the organization's own yesterday. */
async function countCheckinsYesterday(
  supabase: SupabaseClient,
  orgId: string,
  timeZone: string,
  todayLocal: string,
): Promise<number> {
  // Half-open [yesterday 00:00 local, today 00:00 local). Derived from the
  // local dates rather than "now minus 24h" so a check-in at 23:00 IST counts
  // as yesterday and one at 00:30 IST counts as today — the exact case in the
  // brief for this function.
  const start = zonedMidnightUtc(addDays(todayLocal, -1), timeZone);
  const end = zonedMidnightUtc(todayLocal, timeZone);

  const { count, error } = await supabase
    .from("attendance")
    .select("id", { count: "exact", head: true })
    .eq("organization_id", orgId)
    .gte("checked_in_at", start.toISOString())
    .lt("checked_in_at", end.toISOString());

  if (error) throw error;

  return count ?? 0;
}

/** Outbound messages that failed in the last 24h. See DELIVERY_TRACKING above. */
async function countFailedSends(
  supabase: SupabaseClient,
  orgId: string,
): Promise<number> {
  const since = new Date(Date.now() - FAILED_LOOKBACK_HOURS * 3600_000).toISOString();

  const base = () =>
    supabase
      .from("whatsapp_messages")
      .select("id", { count: "exact", head: true })
      .eq("organization_id", orgId)
      .eq("direction", "outbound")
      .gte("created_at", since);

  const { count, error } = await base().eq("status", "failed");
  if (error) throw error;

  let total = count ?? 0;

  if (DELIVERY_TRACKING === "live") {
    // Only meaningful once something actually advances rows out of 'queued'.
    const staleBefore = new Date(Date.now() - STALE_QUEUED_MINUTES * 60_000)
      .toISOString();

    const { count: stale, error: staleError } = await base()
      .eq("status", "queued")
      .lt("created_at", staleBefore);

    if (staleError) throw staleError;

    total += stale ?? 0;
  }

  return total;
}

/**
 * Guard: has this organization already had a brief today (its own calendar day)?
 *
 * Keyed on organization_id + template_name, not member_id — these rows have
 * member_id NULL. direction is pinned too, so a hypothetical inbound row
 * carrying the same template name could never suppress a brief.
 */
async function alreadySentToday(
  supabase: SupabaseClient,
  orgId: string,
  timeZone: string,
  todayLocal: string,
): Promise<boolean> {
  const start = zonedMidnightUtc(todayLocal, timeZone);
  const end = zonedMidnightUtc(addDays(todayLocal, 1), timeZone);

  const { data, error } = await supabase
    .from("whatsapp_messages")
    .select("id")
    .eq("organization_id", orgId)
    .eq("direction", "outbound")
    .eq("template_name", TEMPLATE_NAME)
    .gte("created_at", start.toISOString())
    .lt("created_at", end.toISOString())
    .limit(1);

  if (error) throw error;

  return (data ?? []).length > 0;
}

// ---------------------------------------------------------------------------
// One organization
// ---------------------------------------------------------------------------

async function briefOneOrg(
  supabase: SupabaseClient,
  org: OrgRow,
  timeZone: string,
  dryRun: boolean,
): Promise<OrgResult> {
  const base = {
    organization_id: org.id,
    organization_name: org.name,
    timezone: timeZone,
  };

  const todayLocal = localDate(timeZone);

  // --- Guard: one brief per org per local day ---
  // Skipped in a dry run: a dry run must be able to show the content of a brief
  // that has already gone out today, or it is useless for exactly the moment
  // you most want it (checking what the owner just received).
  if (!dryRun && await alreadySentToday(supabase, org.id, timeZone, todayLocal)) {
    console.log(`[${TAG}] org ${org.id} already briefed today — skipping.`);
    return { ...base, outcome: "skipped", reason: "already_sent_today" };
  }

  // --- Compute ---
  const { due, overdue } = await loadDueAndOverdue(supabase, org.id, todayLocal);

  const stats: BriefStats = {
    renewals_due_count: due.length,
    renewals_due_amount: due.reduce(
      (sum, r) => sum + toAmount(r.membership_plans?.amount),
      0,
    ),
    overdue_count: overdue.length,
    overdue_amount: overdue.reduce(
      (sum, r) => sum + toAmount(r.membership_plans?.amount),
      0,
    ),
    checkins_yesterday: await countCheckinsYesterday(
      supabase,
      org.id,
      timeZone,
      todayLocal,
    ),
    failed_sends: await countFailedSends(supabase, org.id),
  };

  const message = buildBrief(org.name, todayLocal, stats);

  if (dryRun) {
    return { ...base, outcome: "computed", stats, message };
  }

  // --- Recipient check happens AFTER the compute, so a dry run can still show
  // --- the brief for an org whose owner_phone is broken.
  const phone = (org.owner_phone ?? "").trim();
  if (!phone) {
    console.error(
      `[${TAG}] org ${org.id} (${org.name}) has no owner_phone — nobody to send to.`,
    );
    return {
      ...base,
      outcome: "error",
      error: "owner_phone_missing",
      detail: "organizations.owner_phone is empty",
      stats,
    };
  }

  const send = await sendWhatsAppMessage(supabase, phone, message, {
    tag: TAG,
    // NULL on purpose — the recipient is the org's owner, not a member.
    memberId: null,
    organizationId: org.id,
    templateName: TEMPLATE_NAME,
    relatedPaymentId: null,
  });

  if (!send.logged) {
    // The whatsapp_messages row IS the once-per-day guard, so without it a
    // re-run today would message the owner again. Reported, not swallowed.
    console.error(
      `[${TAG}] brief for org ${org.id} was not logged — the once-per-day ` +
        "guard cannot see it.",
    );
    return {
      ...base,
      outcome: "error",
      error: "message_not_logged",
      detail: "the send happened but whatsapp_messages could not be written",
      stats,
      message,
    };
  }

  return {
    ...base,
    outcome: "sent",
    stats,
    message,
    whatsapp_message_id: send.messageId,
  };
}

// ---------------------------------------------------------------------------
// Main flow
// ---------------------------------------------------------------------------

async function handleBrief(req: Request): Promise<Response> {
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

  // Strict boolean: the string "true" must not arm a dry run, and a dry run
  // must never be silently downgraded into a real send to every owner.
  const dryRunRaw = body.dry_run;
  if (dryRunRaw !== undefined && typeof dryRunRaw !== "boolean") {
    return json({
      ok: false,
      error: "dry_run_must_be_boolean",
      detail: `got ${JSON.stringify(dryRunRaw)}`,
    }, 400);
  }
  const dryRun = dryRunRaw === true;

  let onlyOrgId: string | null = null;
  if (body.organization_id !== undefined) {
    if (typeof body.organization_id !== "string" || !UUID_RE.test(body.organization_id.trim())) {
      return json({
        ok: false,
        error: "organization_id_malformed",
        detail: `not a uuid: ${JSON.stringify(body.organization_id)}`,
      }, 400);
    }
    onlyOrgId = body.organization_id.trim();
  }

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

  // --- Select the organizations to brief ---
  let query = supabase
    .from("organizations")
    .select("id,name,owner_phone,status")
    .in("status", BRIEF_ORG_STATUSES as unknown as string[])
    .order("name", { ascending: true })
    .order("id", { ascending: true }) // stable tiebreak
    .limit(limit + 1);

  if (onlyOrgId) query = query.eq("id", onlyOrgId);

  const { data: orgData, error: orgError } = await query;
  if (orgError) throw orgError;

  const allOrgs = (orgData ?? []) as OrgRow[];

  // A targeted request naming an org that does not exist — or is suspended — is
  // a caller mistake worth reporting, not an empty batch to shrug at.
  if (onlyOrgId && allOrgs.length === 0) {
    return json({
      ok: false,
      error: "organization_not_briefable",
      detail:
        `organization ${onlyOrgId} does not exist, or its status is not one of ` +
        BRIEF_ORG_STATUSES.join("/"),
    }, 404);
  }

  const truncated = allOrgs.length > limit;
  const orgs = truncated ? allOrgs.slice(0, limit) : allOrgs;

  const timezones = orgs.length > 0
    ? await loadTimezones(supabase, orgs.map((o) => o.id))
    : new Map<string, string>();

  const common = {
    ok: true,
    dry_run: dryRun,
    organization_count: orgs.length,
    truncated,
    limit,
    delivery_tracking: DELIVERY_TRACKING,
  };

  if (orgs.length === 0) {
    console.log(`[${TAG}] no briefable organizations.`);
    return json({
      ...common,
      sent: 0,
      skipped: 0,
      errored: 0,
      errored_organization_ids: [],
      errors: [],
      results: [],
      duration_ms: Date.now() - startedAt,
    });
  }

  console.log(
    `[${TAG}] ${dryRun ? "DRY RUN over" : "briefing"} ${orgs.length} organization(s)`,
  );

  // --- Fan out. Sequential, but with NO artificial delay: unlike renewal-scan
  // --- this loop calls no external API, so there is no third-party rate limit
  // --- to respect and nothing to gain from pacing. It is only sequential to
  // --- keep the summary ordering stable and the DB load flat.
  const results: OrgResult[] = [];

  for (const org of orgs) {
    const timeZone = timezones.get(org.id) ?? DEFAULT_TIMEZONE;

    try {
      results.push(await briefOneOrg(supabase, org, timeZone, dryRun));
    } catch (err) {
      // (6) One organization's bad data must not cost every other owner their
      // brief. Everything below the org boundary is caught here.
      const detail = err instanceof Error ? err.message : String(err);
      console.error(`[${TAG}] org ${org.id} (${org.name}) failed:`, detail);
      results.push({
        organization_id: org.id,
        organization_name: org.name,
        timezone: timeZone,
        outcome: "error",
        error: "brief_failed",
        detail,
      });
    }
  }

  const count = (o: OrgResult["outcome"]) =>
    results.filter((r) => r.outcome === o).length;
  const errors = results.filter((r) => r.outcome === "error");

  const skippedByReason: Record<string, number> = {};
  for (const r of results) {
    if (r.outcome === "skipped") {
      const key = r.reason ?? "unspecified";
      skippedByReason[key] = (skippedByReason[key] ?? 0) + 1;
    }
  }

  const summary = {
    ...common,
    // "computed" is the dry-run counterpart of "sent" — kept as a distinct name
    // so a dry-run summary can never be mistaken for evidence that messages went out.
    ...(dryRun ? { computed: count("computed") } : { sent: count("sent") }),
    skipped: count("skipped"),
    skipped_by_reason: skippedByReason,
    errored: errors.length,
    errored_organization_ids: errors.map((e) => e.organization_id),
    errors: errors.map((e) => ({
      organization_id: e.organization_id,
      organization_name: e.organization_name,
      error: e.error,
      detail: e.detail,
    })),
    results,
    duration_ms: Date.now() - startedAt,
  };

  console.log(
    `[${TAG}] done: ${dryRun ? count("computed") + " computed" : count("sent") + " sent"}, ` +
      `${count("skipped")} skipped, ${errors.length} errored in ${summary.duration_ms}ms`,
  );

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
    return await handleBrief(req);
  } catch (err) {
    // A 5xx here means the RUN broke (the organizations query failed), not that
    // an individual org's brief did — those are collected into `errors` and
    // still return 200.
    console.error(`[${TAG}] unhandled failure:`, err);
    return json({
      ok: false,
      error: "internal_error",
      detail: err instanceof Error ? err.message : String(err),
    }, 500);
  }
});
