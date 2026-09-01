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
//       payments, attendance, pt_packages, training_notes and whatsapp_messages
//       at request time.
//
// REAL: the outbound send, via the shared helper in ../_shared/whatsapp.ts —
//       a real call to Meta's Cloud API, using an APPROVED template.
//       WHATSAPP_SEND_MODE=mock skips the real call; this function's test.sh
//       enforces that for automated runs.
//
// ============================================================================
// TEMPLATE VERSION — v2 is the default, v1 is kept for rollback
// ============================================================================
// v1 (daily_owner_brief, 7 params): the original renewals/overdue/check-ins
//     summary. buildBrief() + the 7-element bodyParams below. UNTOUCHED.
// v2 (daily_owner_brief_v2, 12 params, approved): adds this-month revenue with
//     the membership/PT split, an attention-items roll-up, and coach activity.
//     buildBriefV2() + the 12-element bodyParams.
//
// Which one a send uses:
//   * default: DAILY_BRIEF_TEMPLATE_VERSION env (unset => "v2").
//   * per request: { "template_version": "v1" | "v2" } overrides it — so an
//     operator can roll back one run, or a dry run can preview either format,
//     without touching secrets.
// Rollback to v1 everywhere: `supabase secrets set DAILY_BRIEF_TEMPLATE_VERSION=v1`.
//
// The v2 numbers are computed to MATCH the owner-facing WhatsApp commands
// exactly — same sources, same rules — so the brief and REVENUE / PT / COACHES
// never disagree for the same org:
//   * revenue + membership/PT split : v_daily_revenue_by_source, current
//     calendar month (ownerRevenue in whatsapp-webhook reads the same view).
//   * PT alerts : the low-sessions / expiring-soon predicate recomputed from
//     pt_packages (identical to loadAttention() / v_pt_packages_attention —
//     the view's WHERE is auth.jwt()-bound so a service_role caller must
//     recompute, exactly as whatsapp-webhook's PT/ALERTS commands already do).
//   * coaches "active" + "need a check-in" : role='coach' count, and of those
//     how many have no training_note in the last 7 days — the same
//     logging-recently rule as ownerCoaches().
//   * yesterday's sessions logged : training_notes.session_date = yesterday,
//     same column ownerToday() counts on.
//
// The v1 template body has no "failed sends" line, so buildBrief()'s ❌ line is
// preview/body_preview content only, never a v1 body param. v2 likewise carries
// no failed-sends param.
//
// ============================================================================
// THE RECIPIENTS ARE AN ORGANIZATION'S OWNERS, NOT A MEMBER
// ============================================================================
// Every other outbound message in this system goes to a member. This one goes
// to EVERY owner of the gym — organizations.owner_phone AND every users row
// with role='owner' for that org, deduped by phone (a gym can have 2+ real
// co-owners). Each distinct phone gets its own copy; the whatsapp_messages row
// for each has member_id = NULL. That is allowed (the column has no NOT NULL
// constraint) and it does not disturb anything downstream:
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

// v1 = the original 7-param template; v2 = the approved 12-param richer one.
const TEMPLATE_NAME_V1 = "daily_owner_brief" as const;
const TEMPLATE_NAME_V2 = "daily_owner_brief_v2" as const;
// Both names, for the once-per-day-per-org guard: one brief per org per day
// regardless of which template version produced it (so flipping the version
// mid-day can never double-send).
const BRIEF_TEMPLATE_NAMES = [TEMPLATE_NAME_V1, TEMPLATE_NAME_V2] as const;
// Locale code the templates are registered under. Kept as one constant for
// both versions — v2 was registered the same way v1 was.
const TEMPLATE_LANGUAGE = "en" as const;

type BriefVersion = "v1" | "v2";

/** Default template version for a send. Per-request `template_version` overrides. */
const DEFAULT_BRIEF_VERSION: BriefVersion =
  (Deno.env.get("DAILY_BRIEF_TEMPLATE_VERSION") ?? "v2").trim().toLowerCase() === "v1"
    ? "v1"
    : "v2";

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

  // --- v2 only. Left undefined on a v1 brief (so they don't appear in the
  // --- v1 dry-run JSON at all). ---
  /** This calendar month's collected revenue, membership + PT. */
  revenue_month_total?: number;
  revenue_month_membership?: number;
  revenue_month_pt?: number;
  /** PT packages flagged low-on-sessions OR expiring-soon (same rule as PT/ALERTS). */
  pt_alert_count?: number;
  /** overdue_count + pt_alert_count — the "needs attention" roll-up. */
  attention_items?: number;
  /** users with role='coach' for this org (same denominator as the COACHES command). */
  coaches_active?: number;
  /** of those, how many have logged no session in the last 7 days. */
  coaches_need_checkin?: number;
  /** training_notes with session_date = the org's yesterday. */
  sessions_logged_yesterday?: number;
}

interface OrgResult {
  organization_id: string;
  organization_name: string;
  outcome: "sent" | "skipped" | "error" | "computed";
  /** which template version produced (or would produce) this brief. */
  brief_version?: BriefVersion;
  reason?: string;
  error?: string;
  detail?: string;
  timezone?: string;
  stats?: BriefStats;
  message?: string;
  whatsapp_message_id?: string | null;
  /** distinct owner phones this org's brief was addressed to */
  recipients?: number;
  /** of those, how many the send actually reached (queued/sent, not failed) */
  recipients_delivered?: number;
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
 * Add whole months to YYYY-MM-DD, clamping the day to the target month's end.
 * Matches whatsapp-webhook's addMonthsStr() and Postgres'
 * `(start_date + make_interval(months => n))::date` that v_pt_packages_attention
 * uses — so the "expiring soon" flag lines up exactly with the PT/ALERTS command.
 */
function addMonthsIso(isoDate: string, months: number): string {
  const [y, m, d] = isoDate.split("-").map(Number);
  const total = y * 12 + (m - 1) + months;
  const ty = Math.floor(total / 12);
  const tm = (total % 12) + 1;
  const lastDay = new Date(Date.UTC(ty, tm, 0)).getUTCDate();
  const cd = Math.min(d, lastDay);
  return `${String(ty).padStart(4, "0")}-${String(tm).padStart(2, "0")}-${String(cd).padStart(2, "0")}`;
}

/** Whole days from `fromIso` to `toIso` (negative if `toIso` is earlier). */
function daysBetweenIso(fromIso: string, toIso: string): number {
  const [fy, fm, fd] = fromIso.split("-").map(Number);
  const [ty, tm, td] = toIso.split("-").map(Number);
  return Math.round((Date.UTC(ty, tm - 1, td) - Date.UTC(fy, fm - 1, fd)) / 86400000);
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

/**
 * v2 brief text — the body_preview / dry-run rendering of the approved
 * daily_owner_brief_v2 template:
 *
 *   "Good morning! {{1}} — {{2}}. Revenue this month: ₹{{3}} (₹{{4}} membership,
 *    ₹{{5}} PT). Needs attention: {{6}} items — {{7}} overdue, {{8}} PT alerts.
 *    Coaches: {{9}} active, {{10}} need a check-in. Yesterday: {{11}} check-ins,
 *    {{12}} sessions logged."
 *
 * Rendered as one paragraph so body_preview reads exactly like the delivered
 * message. The 12 params handed to Meta are built separately in briefOneOrg().
 */
function buildBriefV2(orgName: string, todayLocal: string, s: BriefStats): string {
  return (
    `Good morning! ${orgName} — ${formatDateForOwner(todayLocal)}. ` +
    `Revenue this month: ₹${formatRupees(s.revenue_month_total ?? 0)} ` +
    `(₹${formatRupees(s.revenue_month_membership ?? 0)} membership, ` +
    `₹${formatRupees(s.revenue_month_pt ?? 0)} PT). ` +
    `Needs attention: ${s.attention_items ?? 0} items — ` +
    `${s.overdue_count} overdue, ${s.pt_alert_count ?? 0} PT alerts. ` +
    `Coaches: ${s.coaches_active ?? 0} active, ${s.coaches_need_checkin ?? 0} need a check-in. ` +
    `Yesterday: ${s.checkins_yesterday} check-ins, ${s.sessions_logged_yesterday ?? 0} sessions logged.`
  );
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

// ---------------------------------------------------------------------------
// v2-only per-org data. Each mirrors the owner-facing WhatsApp command that
// reports the same number, so the brief and the command can never disagree.
// ---------------------------------------------------------------------------

/**
 * This calendar month's collected revenue, split membership vs PT.
 *
 * Same source and shape as ownerRevenue() in whatsapp-webhook: read
 * v_daily_revenue_by_source, keep rows from the 1st of the current month
 * onward, partition by `source`. The view is security_invoker=true; a
 * service_role caller (this function) bypasses RLS and gets every org's rows,
 * so the organization_id filter is what scopes it — exactly as ownerRevenue does.
 */
async function loadMonthRevenue(
  supabase: SupabaseClient,
  orgId: string,
  todayLocal: string,
): Promise<{ total: number; membership: number; pt: number }> {
  const monthStart = `${todayLocal.slice(0, 7)}-01`; // YYYY-MM-01

  const { data, error } = await supabase
    .from("v_daily_revenue_by_source")
    .select("source, total")
    .eq("organization_id", orgId)
    .gte("day", monthStart);
  if (error) throw error;

  let membership = 0;
  let pt = 0;
  for (const r of (data ?? []) as { source: string; total: number | string }[]) {
    const amt = toAmount(r.total);
    if (r.source === "pt_package") pt += amt;
    else membership += amt;
  }
  return { total: membership + pt, membership, pt };
}

/**
 * How many ACTIVE PT packages need attention: low on sessions OR expiring soon.
 * Identical predicate to loadAttention() in whatsapp-webhook (PT / ALERTS
 * commands) and to v_pt_packages_attention:
 *   low       = sessions_purchased - sessions_used <= 2
 *   expiring  = (start_date + duration_months months, clamped) is <= 7 days out
 *               (negative days_until_end — already past — still counts)
 * The view's own WHERE is auth.jwt()-bound, so a service_role caller must
 * recompute from pt_packages, which is what the commands do too.
 */
async function countPtAlerts(
  supabase: SupabaseClient,
  orgId: string,
  todayLocal: string,
): Promise<number> {
  const { data, error } = await supabase
    .from("pt_packages")
    .select("sessions_purchased, sessions_used, start_date, duration_months")
    .eq("organization_id", orgId)
    .eq("status", "active");
  if (error) throw error;

  let count = 0;
  for (const p of (data ?? []) as any[]) {
    const remaining = Number(p.sessions_purchased) - Number(p.sessions_used);
    const endDate = addMonthsIso(String(p.start_date).slice(0, 10), Number(p.duration_months));
    const daysUntilEnd = daysBetweenIso(todayLocal, endDate);
    if (remaining <= 2 || daysUntilEnd <= 7) count++;
  }
  return count;
}

/**
 * Coach activity: how many coaches on the team, and of those how many have not
 * logged a session in the last 7 days. Same rule as ownerCoaches():
 *   active       = users with role='coach' for this org
 *   need-checkin = active coaches with no training_notes row whose created_at
 *                  is within the last 7 days (rolling, not midnight-aligned)
 */
async function loadCoachActivity(
  supabase: SupabaseClient,
  orgId: string,
): Promise<{ active: number; need_checkin: number }> {
  const recentSince = new Date(Date.now() - 7 * 86_400_000).toISOString();

  const [coachRes, recentRes] = await Promise.all([
    supabase.from("users").select("id").eq("organization_id", orgId).eq("role", "coach"),
    supabase.from("training_notes").select("coach_id").eq("organization_id", orgId)
      .gte("created_at", recentSince),
  ]);
  if (coachRes.error) throw coachRes.error;
  if (recentRes.error) throw recentRes.error;

  const coachIds = (coachRes.data ?? []).map((c: any) => c.id as string);
  const loggedRecently = new Set((recentRes.data ?? []).map((r: any) => r.coach_id as string));
  const need = coachIds.filter((id) => !loggedRecently.has(id)).length;

  return { active: coachIds.length, need_checkin: need };
}

/** PT sessions logged during the org's yesterday — training_notes.session_date. */
async function countSessionsLoggedYesterday(
  supabase: SupabaseClient,
  orgId: string,
  todayLocal: string,
): Promise<number> {
  const { count, error } = await supabase
    .from("training_notes")
    .select("id", { count: "exact", head: true })
    .eq("organization_id", orgId)
    .eq("session_date", addDays(todayLocal, -1));
  if (error) throw error;
  return count ?? 0;
}

/**
 * Guard: has this organization already had a brief today (its own calendar day)?
 *
 * Keyed on organization_id + template_name, not member_id — these rows have
 * member_id NULL. direction is pinned too, so a hypothetical inbound row
 * carrying the same template name could never suppress a brief. Matches EITHER
 * template version's name: one brief per org per day, whichever produced it.
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
    .in("template_name", BRIEF_TEMPLATE_NAMES as unknown as string[])
    .gte("created_at", start.toISOString())
    .lt("created_at", end.toISOString())
    .limit(1);

  if (error) throw error;

  return (data ?? []).length > 0;
}

/**
 * Every phone that should receive this org's brief: organizations.owner_phone
 * PLUS every users row with role='owner' for the org, trimmed and deduped.
 *
 * owner_phone is kept in the mix on purpose (see requirement/DECISION note in
 * the header): it is the signup / billing contact and the only recipient for
 * an org that has no owner-role users bridged yet. If the same person is both
 * owner_phone and an owner-role user, the Set collapses them to one send.
 */
async function loadOwnerRecipients(
  supabase: SupabaseClient,
  org: OrgRow,
): Promise<string[]> {
  const { data, error } = await supabase
    .from("users")
    .select("phone")
    .eq("organization_id", org.id)
    .eq("role", "owner");
  if (error) throw error;

  const phones = new Set<string>();
  const add = (p: string | null | undefined) => {
    const t = (p ?? "").trim();
    if (t) phones.add(t);
  };
  add(org.owner_phone);
  for (const u of data ?? []) add((u as { phone: string | null }).phone);
  return [...phones];
}

// ---------------------------------------------------------------------------
// One organization
// ---------------------------------------------------------------------------

async function briefOneOrg(
  supabase: SupabaseClient,
  org: OrgRow,
  timeZone: string,
  dryRun: boolean,
  version: BriefVersion,
): Promise<OrgResult> {
  const base = {
    organization_id: org.id,
    organization_name: org.name,
    timezone: timeZone,
    brief_version: version,
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

  // --- v2 adds revenue, PT alerts, coach activity, yesterday's sessions. v1
  // --- is left byte-for-byte as it was: none of this runs, none of it ships. ---
  if (version === "v2") {
    const [revenue, ptAlerts, coaches, sessionsYesterday] = await Promise.all([
      loadMonthRevenue(supabase, org.id, todayLocal),
      countPtAlerts(supabase, org.id, todayLocal),
      loadCoachActivity(supabase, org.id),
      countSessionsLoggedYesterday(supabase, org.id, todayLocal),
    ]);
    stats.revenue_month_total = revenue.total;
    stats.revenue_month_membership = revenue.membership;
    stats.revenue_month_pt = revenue.pt;
    stats.pt_alert_count = ptAlerts;
    stats.attention_items = stats.overdue_count + ptAlerts;
    stats.coaches_active = coaches.active;
    stats.coaches_need_checkin = coaches.need_checkin;
    stats.sessions_logged_yesterday = sessionsYesterday;
  }

  const message = version === "v2"
    ? buildBriefV2(org.name, todayLocal, stats)
    : buildBrief(org.name, todayLocal, stats);

  if (dryRun) {
    return { ...base, outcome: "computed", stats, message };
  }

  // --- Recipient list is resolved AFTER the compute, so a dry run can still
  // --- show the brief for an org whose owner contacts are broken.
  const recipients = await loadOwnerRecipients(supabase, org);
  if (recipients.length === 0) {
    console.error(
      `[${TAG}] org ${org.id} (${org.name}) has no owner recipient — no ` +
        "organizations.owner_phone and no users role='owner'.",
    );
    return {
      ...base,
      outcome: "error",
      error: "owner_phone_missing", // kept for callers/tests; detail widened
      detail: "no organizations.owner_phone and no users role='owner'",
      stats,
    };
  }

  const templateName = version === "v2" ? TEMPLATE_NAME_V2 : TEMPLATE_NAME_V1;

  // Body params in template order. v1 = 7 (unchanged). v2 = 12, matching the
  // approved daily_owner_brief_v2 body:
  //   {{1}} org  {{2}} date  {{3}} revenue total  {{4}} membership  {{5}} PT
  //   {{6}} attention items  {{7}} overdue  {{8}} PT alerts
  //   {{9}} coaches active  {{10}} coaches needing a check-in
  //   {{11}} yesterday check-ins  {{12}} yesterday sessions logged
  // The ₹ signs are literals IN the template, so {{3}}/{{4}}/{{5}} are the bare
  // grouped numbers. failed_sends is never a param in either version.
  const bodyParams = version === "v2"
    ? [
      org.name,
      formatDateForOwner(todayLocal),
      formatRupees(stats.revenue_month_total ?? 0),
      formatRupees(stats.revenue_month_membership ?? 0),
      formatRupees(stats.revenue_month_pt ?? 0),
      String(stats.attention_items ?? 0),
      String(stats.overdue_count),
      String(stats.pt_alert_count ?? 0),
      String(stats.coaches_active ?? 0),
      String(stats.coaches_need_checkin ?? 0),
      String(stats.checkins_yesterday),
      String(stats.sessions_logged_yesterday ?? 0),
    ]
    : [
      org.name,
      formatDateForOwner(todayLocal),
      String(stats.renewals_due_count),
      formatRupees(stats.renewals_due_amount),
      String(stats.overdue_count),
      formatRupees(stats.overdue_amount),
      String(stats.checkins_yesterday),
    ];

  // One send per distinct owner phone. The once-per-day guard above is
  // per-ORG, so a re-run the same day skips the whole org (nobody is
  // re-messaged); within THIS run the deduped list guarantees each phone is
  // messaged once. Each send writes its own whatsapp_messages row.
  let logged = 0;
  let delivered = 0;
  let lastMessageId: string | null = null;
  for (const phone of recipients) {
    const send = await sendWhatsAppMessage(supabase, phone, message, {
      tag: TAG,
      memberId: null, // NULL on purpose — the recipient is an owner, not a member.
      organizationId: org.id,
      templateName,
      relatedPaymentId: null,
    }, {
      name: templateName,
      language: TEMPLATE_LANGUAGE,
      bodyParams,
    });
    if (send.logged) logged++;
    if (send.status !== "failed") delivered++;
    if (send.messageId) lastMessageId = send.messageId;
  }

  if (logged === 0) {
    // The whatsapp_messages row IS the once-per-day guard, so with none
    // written a re-run today would message every owner again.
    console.error(
      `[${TAG}] brief for org ${org.id} wrote NO whatsapp_messages row across ` +
        `${recipients.length} recipient(s) — the once-per-day guard cannot see it.`,
    );
    return {
      ...base,
      outcome: "error",
      error: "message_not_logged",
      detail: "sends happened but no whatsapp_messages row could be written",
      stats,
      message,
      recipients: recipients.length,
      recipients_delivered: 0,
    };
  }

  if (delivered === 0) {
    // At least one row was logged (so the org won't be retried today), but
    // Meta rejected every send — no owner actually received the brief.
    console.error(
      `[${TAG}] brief for org ${org.id} was logged but Meta rejected all ` +
        `${recipients.length} owner send(s) (status=failed).`,
    );
    return {
      ...base,
      outcome: "error",
      error: "send_failed",
      detail: `whatsapp_messages rows were written but every Meta send failed`,
      stats,
      message,
      recipients: recipients.length,
      recipients_delivered: 0,
      whatsapp_message_id: lastMessageId,
    };
  }

  return {
    ...base,
    outcome: "sent",
    stats,
    message,
    recipients: recipients.length,
    recipients_delivered: delivered,
    whatsapp_message_id: lastMessageId,
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

  // Optional per-request override of DEFAULT_BRIEF_VERSION — lets an operator
  // roll one run back to v1, or a dry run preview either format, without
  // touching the DAILY_BRIEF_TEMPLATE_VERSION secret.
  let version: BriefVersion = DEFAULT_BRIEF_VERSION;
  if (body.template_version !== undefined) {
    if (body.template_version !== "v1" && body.template_version !== "v2") {
      return json({
        ok: false,
        error: "template_version_invalid",
        detail: `expected "v1" or "v2", got ${JSON.stringify(body.template_version)}`,
      }, 400);
    }
    version = body.template_version;
  }

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
    brief_version: version,
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
      results.push(await briefOneOrg(supabase, org, timeZone, dryRun, version));
    } catch (err) {
      // (6) One organization's bad data must not cost every other owner their
      // brief. Everything below the org boundary is caught here.
      const detail = err instanceof Error ? err.message : String(err);
      console.error(`[${TAG}] org ${org.id} (${org.name}) failed:`, detail);
      results.push({
        organization_id: org.id,
        organization_name: org.name,
        timezone: timeZone,
        brief_version: version,
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
