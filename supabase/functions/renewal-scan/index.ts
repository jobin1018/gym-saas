// renewal-scan — find the memberships due for a renewal reminder and fan out to
// send-renewal-reminder, one call per membership.
//
// POST {}                        -> scan and send
// POST { "dry_run": true }       -> scan and REPORT, send nothing
// POST { "offsets": [7,3,-3] }   -> override which days before/after due to hit
// POST { "limit": 50 }           -> cap the batch
//
// Triggered daily by pg_cron (see the cron migration), and directly by curl for
// testing.
//
// ============================================================================
// THIS FUNCTION OWNS SELECTION. IT DOES NOT OWN POLICY.
// ============================================================================
// send-renewal-reminder already refuses to re-send the same day, re-charge the
// same period, message an opted-out member, or chase a paid renewal. None of
// that is repeated here — this function decides only WHICH memberships to offer
// up, and reports what came back.
//
// The one thing that follows from that split: whether a member is spammed is
// decided HERE, not there. send-renewal-reminder's guard is once-per-DAY, so it
// will happily send on eight consecutive days if this function offers the same
// membership eight days running. See the offsets note below.
//
// This function performs NO writes. Every row written during a scan is written
// by send-renewal-reminder, under its own grants.
// ============================================================================

import "@supabase/functions-js/edge-runtime.d.ts";
import { createAdminClient, type SupabaseClient } from "../_shared/supabase.ts";
import { authorizeServiceRole, expectedServiceRoleKey } from "../_shared/auth.ts";

const TAG = "renewal-scan";

// Same default and same reasoning as BILLING_TIMEZONE in razorpay-webhook and
// REMINDER_TIMEZONE in send-renewal-reminder: current_period_end is a DATE, and
// "today" for a gym in IST is not "today" in UTC between 00:00 and 05:30 IST.
// The cron job fires at 01:30 UTC (= 07:00 IST), which lands squarely in that
// gap — getting this wrong would shift the whole schedule by a day.
const BILLING_TIMEZONE = Deno.env.get("BILLING_TIMEZONE") ?? "Asia/Kolkata";

// ---------------------------------------------------------------------------
// WHICH DAYS TO REMIND ON — the most consequential setting in this file
// ---------------------------------------------------------------------------
// These are DISCRETE day offsets, not a range: a membership is selected when
// current_period_end is EXACTLY today + N for some N in this list. Positive is
// "days before due", 0 is the due date itself, negative is dunning after it.
//
// WHY NOT A CONTIGUOUS WINDOW. A range like `current_period_end BETWEEN today
// AND today + 3` looks equivalent but is not, because a DAILY scan re-selects
// the same membership every day as it counts down — and send-renewal-reminder's
// only messaging guard is once-per-DAY, not once-per-period. One renewal would
// generate four messages on a 0..3 range, eight on 0..7. Discrete offsets give
// exactly one message per offset, which is what the two-reminder design in
// send-renewal-reminder/index.ts already describes:
//
//   "day 7 and day 3 reminders for the same renewal reuse ONE payments row
//    and ONE payment link"
//
// Hence the default 7,3. Both reminders reuse the same payments row and the
// same Razorpay link — that is the money guard doing its job, and it is why
// sending twice is safe where sending eight times would merely be rude.
//
// NOTE ON status='past_due': it is included in the query below, but with
// positive-only offsets it will almost never match, because a past_due
// membership is one whose period has ALREADY ended (current_period_end < today,
// like the seeded fixture at CURRENT_DATE - 10). Chasing those is a dunning
// policy and a real-money decision, so it is off by default rather than
// guessed at. Turn it on by adding negative offsets, e.g.
//   REMINDER_OFFSET_DAYS="7,3,-3,-7"
// which reminds a week out, three days out, three days late and a week late.
const DEFAULT_OFFSET_DAYS = "7,3";

// Statuses worth reminding. 'expired' and 'cancelled' are deliberately absent:
// a cancelled member has asked not to be billed, and chasing them for money is
// the kind of thing that ends up on social media.
const SCAN_STATUSES = ["active", "past_due"] as const;

// Pace the fan-out. See pickDelay() for the reasoning.
const DEFAULT_DELAY_MS = 250;

// Cap on one scan's batch. Hosted Edge Functions have a wall-clock ceiling, and
// a scan that trips it dies mid-fan-out with no summary — the worst possible
// failure mode for a scheduled job, because nothing reports it. A bounded batch
// that says `truncated: true` is strictly better: it finishes, and it tells you.
const DEFAULT_LIMIT = 100;
const MAX_LIMIT = 1000;

const REMINDER_FUNCTION = "send-renewal-reminder";

const MEMBERSHIP_SELECT =
  "id,organization_id,member_id,plan_id,status,current_period_end," +
  "members(id,name,phone,whatsapp_opt_in)," +
  "membership_plans(id,name,amount)";

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

interface MembershipRow {
  id: string;
  organization_id: string;
  member_id: string;
  plan_id: string;
  status: string;
  current_period_end: string;
  members:
    | { id: string; name: string; phone: string; whatsapp_opt_in: boolean }
    | null;
  membership_plans: { id: string; name: string; amount: number | string } | null;
}

type Outcome = "created" | "reused" | "skipped" | "error";

interface ScanResult {
  membership_id: string;
  member_name: string | null;
  outcome: Outcome;
  /** Skips only: already_sent_today | whatsapp_opt_out | already_paid | ... */
  reason?: string;
  /** Errors only. */
  error?: string;
  detail?: string;
  http_status?: number;
  payment_id?: string;
  razorpay_link_id?: string;
  payment_url?: string;
}

interface DryRunEntry {
  membership_id: string;
  organization_id: string;
  member_id: string;
  member_name: string | null;
  member_phone: string | null;
  /** Reported, NOT acted on — the opt-in decision belongs to send-renewal-reminder. */
  whatsapp_opt_in: boolean | null;
  plan_name: string | null;
  amount: number | null;
  membership_status: string;
  current_period_end: string;
  days_until_due: number;
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

/**
 * Today as YYYY-MM-DD in the billing timezone. en-CA formats as ISO.
 * Same helper as razorpay-webhook's todayInBillingTimezone().
 */
function todayInBillingTimezone(): string {
  return new Intl.DateTimeFormat("en-CA", {
    timeZone: BILLING_TIMEZONE,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).format(new Date());
}

/**
 * Add `days` to a YYYY-MM-DD string and return YYYY-MM-DD.
 *
 * UTC arithmetic on a date-only value, which is exactly right here:
 * current_period_end is a DATE column with no time or zone of its own, so once
 * "today" has been resolved in the billing timezone above, offsetting it is
 * pure calendar arithmetic. Going through local time would reintroduce DST.
 */
function addDays(isoDate: string, days: number): string {
  const [y, m, d] = isoDate.split("-").map(Number);
  return new Date(Date.UTC(y, m - 1, d + days)).toISOString().slice(0, 10);
}

/** Whole days from `from` to `to`, both YYYY-MM-DD. */
function daysBetween(from: string, to: string): number {
  const [fy, fm, fd] = from.split("-").map(Number);
  const [ty, tm, td] = to.split("-").map(Number);
  return Math.round(
    (Date.UTC(ty, tm - 1, td) - Date.UTC(fy, fm - 1, fd)) / 86_400_000,
  );
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

/**
 * Parse "7,3" or [7,3] into a de-duplicated list of day offsets, sorted
 * descending so the earliest reminder (furthest from due) is listed first.
 */
function parseOffsets(raw: unknown): number[] | null {
  let parts: unknown[];

  if (Array.isArray(raw)) {
    parts = raw;
  } else if (typeof raw === "string") {
    parts = raw.split(",").map((s) => s.trim()).filter(Boolean);
  } else {
    return null;
  }

  const out: number[] = [];
  for (const p of parts) {
    const n = Number(p);
    // Integers only: current_period_end is a DATE, so 1.5 has no meaning and
    // would silently select nothing.
    if (!Number.isInteger(n) || Math.abs(n) > 365) return null;
    if (!out.includes(n)) out.push(n);
  }

  return out.length > 0 ? out.sort((a, b) => b - a) : null;
}

/**
 * How long to wait between reminders.
 *
 * Warranted, but modestly. Each send-renewal-reminder call makes one or two
 * REAL Razorpay API calls, and this loop is the only place in the system that
 * makes them back-to-back. Two things make a delay cheap insurance rather than
 * superstition:
 *
 *   1. Razorpay rate-limits per account. A burst of link creations from a
 *      single account is exactly the shape that trips it, and a 429 here costs
 *      a member their reminder for the day.
 *   2. Payment link creation is not free at Razorpay's end. Pacing keeps a
 *      runaway scan (a bad offsets override, say) from doing damage at full
 *      speed before anyone notices.
 *
 * What does most of the work, though, is that the loop is SEQUENTIAL rather
 * than parallel — that alone caps throughput at roughly one call per round
 * trip. The delay just adds headroom, so it is deliberately small: at 250ms a
 * 100-membership batch spends 25s waiting, affordable inside one invocation.
 * Set RENEWAL_SCAN_DELAY_MS=0 to turn it off.
 */
function pickDelay(): number {
  const raw = Deno.env.get("RENEWAL_SCAN_DELAY_MS");
  if (raw === undefined) return DEFAULT_DELAY_MS;

  const n = Number(raw);
  return Number.isFinite(n) && n >= 0 && n <= 10_000 ? n : DEFAULT_DELAY_MS;
}

/** http://kong:8000 locally, https://<ref>.supabase.co when deployed. */
function reminderUrl(): string | null {
  const override = Deno.env.get("SEND_RENEWAL_REMINDER_URL");
  if (override) return override;

  const base = Deno.env.get("SUPABASE_URL");
  return base
    ? `${base.replace(/\/+$/, "")}/functions/v1/${REMINDER_FUNCTION}`
    : null;
}

// ---------------------------------------------------------------------------
// Selection — the only database access this function makes
// ---------------------------------------------------------------------------

/**
 * The memberships due for a reminder today.
 *
 * `.in("current_period_end", dates)` rather than a range — see the long note on
 * offsets above. Ordered by current_period_end ascending so the most urgent
 * renewals go out first: if the batch is truncated or the invocation dies
 * partway, the people closest to losing access have already been told.
 */
async function selectDueMemberships(
  supabase: SupabaseClient,
  dates: string[],
  limit: number,
): Promise<MembershipRow[]> {
  const { data, error } = await supabase
    .from("memberships")
    .select(MEMBERSHIP_SELECT)
    .in("status", SCAN_STATUSES as unknown as string[])
    .in("current_period_end", dates)
    .order("current_period_end", { ascending: true })
    .order("id", { ascending: true }) // stable tiebreak, so runs are reproducible
    .limit(limit + 1); // +1 detects "there was more" without a second count query

  if (error) throw error;

  return (data ?? []) as MembershipRow[];
}

// ---------------------------------------------------------------------------
// Fan-out
// ---------------------------------------------------------------------------

/**
 * Call send-renewal-reminder for one membership and classify what came back.
 *
 * NEVER THROWS. A scheduled job that abandons 60 memberships because the 61st
 * had a bad plan amount is worse than useless, so every failure mode — network,
 * non-JSON body, 5xx, unrecognised shape — becomes an "error" result and the
 * scan moves on. The membership id is reported so a human can retry that one
 * membership by hand.
 */
async function sendOne(
  url: string,
  serviceKey: string,
  membership: MembershipRow,
): Promise<ScanResult> {
  const base = {
    membership_id: membership.id,
    member_name: membership.members?.name ?? null,
  };

  let res: Response;
  try {
    res = await fetch(url, {
      method: "POST",
      headers: {
        authorization: `Bearer ${serviceKey}`,
        "content-type": "application/json",
      },
      body: JSON.stringify({ membership_id: membership.id }),
    });
  } catch (err) {
    return {
      ...base,
      outcome: "error",
      error: "request_failed",
      detail: err instanceof Error ? err.message : String(err),
    };
  }

  const body = await res.json().catch(() => null);

  if (body === null) {
    return {
      ...base,
      outcome: "error",
      error: "unparseable_response",
      http_status: res.status,
    };
  }

  // send-renewal-reminder answers ok:false with an `error` string on every
  // failure path it knows about (membership_not_found, razorpay_error,
  // plan_amount_invalid, payment_link_unrecoverable, ...).
  if (!res.ok || body.ok !== true) {
    return {
      ...base,
      outcome: "error",
      error: typeof body.error === "string" ? body.error : "unknown_error",
      detail: typeof body.detail === "string" ? body.detail : undefined,
      http_status: res.status,
    };
  }

  if (typeof body.skipped === "string") {
    return { ...base, outcome: "skipped", reason: body.skipped };
  }

  if (body.created === true || body.reused === true) {
    return {
      ...base,
      outcome: body.created === true ? "created" : "reused",
      payment_id: body.payment_id,
      razorpay_link_id: body.razorpay_link_id,
      payment_url: body.payment_url,
    };
  }

  // ok:true but neither created/reused/skipped — a shape this function does not
  // know. Surfaced rather than silently counted as a success, so a future change
  // to send-renewal-reminder's response cannot quietly corrupt the summary.
  return {
    ...base,
    outcome: "error",
    error: "unrecognised_response_shape",
    detail: JSON.stringify(body).slice(0, 200),
    http_status: res.status,
  };
}

// ---------------------------------------------------------------------------
// Main flow
// ---------------------------------------------------------------------------

async function handleScan(req: Request): Promise<Response> {
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

  // Strict: only boolean `true` arms a dry run. If someone sends the STRING
  // "true" we reject rather than guess — and, far more importantly, a typo like
  // {"dryrun":true} must never be silently treated as a real run. It is not,
  // because an unknown key leaves dry_run undefined... which is exactly why the
  // real-run path is the one that has to be explicitly asked for in testing.
  const dryRunRaw = body.dry_run;
  if (dryRunRaw !== undefined && typeof dryRunRaw !== "boolean") {
    return json({
      ok: false,
      error: "dry_run_must_be_boolean",
      detail: `got ${JSON.stringify(dryRunRaw)}`,
    }, 400);
  }
  const dryRun = dryRunRaw === true;

  const offsets = parseOffsets(
    body.offsets ?? Deno.env.get("REMINDER_OFFSET_DAYS") ?? DEFAULT_OFFSET_DAYS,
  );
  if (!offsets) {
    return json({
      ok: false,
      error: "offsets_invalid",
      detail: 'expected a non-empty list of whole days, e.g. [7,3] or "7,3"',
    }, 400);
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

  const today = todayInBillingTimezone();
  const targetDates = offsets.map((n) => addDays(today, n));

  const supabase = createAdminClient();
  const rows = await selectDueMemberships(supabase, targetDates, limit);

  const truncated = rows.length > limit;
  const batch = truncated ? rows.slice(0, limit) : rows;

  const common = {
    ok: true,
    dry_run: dryRun,
    scan_date: today,
    timezone: BILLING_TIMEZONE,
    offset_days: offsets,
    target_dates: targetDates,
    statuses: SCAN_STATUSES,
    matched: batch.length,
    truncated,
    limit,
  };

  // --- (5) DRY RUN: same query, same ordering, no calls, no writes ---
  if (dryRun) {
    const wouldSend: DryRunEntry[] = batch.map((m) => ({
      membership_id: m.id,
      organization_id: m.organization_id,
      member_id: m.member_id,
      member_name: m.members?.name ?? null,
      member_phone: m.members?.phone ?? null,
      whatsapp_opt_in: m.members?.whatsapp_opt_in ?? null,
      plan_name: m.membership_plans?.name ?? null,
      amount: m.membership_plans ? Number(m.membership_plans.amount) : null,
      membership_status: m.status,
      current_period_end: m.current_period_end,
      days_until_due: daysBetween(today, m.current_period_end),
    }));

    console.log(
      `[${TAG}] DRY RUN — ${wouldSend.length} membership(s) match ` +
        `${targetDates.join(", ")}; nothing was sent.`,
    );

    return json({
      ...common,
      would_send: wouldSend,
      total_amount: wouldSend.reduce((sum, e) => sum + (e.amount ?? 0), 0),
      // Stated plainly so a dry run is not mistaken for a forecast. This
      // function reports what it would OFFER; send-renewal-reminder decides
      // what actually happens to each one, and those guards are not evaluated
      // here (doing so would duplicate them, and duplicated guards drift).
      note:
        "Selection only. send-renewal-reminder may still skip a listed " +
        "membership (already reminded today, already paid, opted out) — those " +
        "guards are not evaluated by a dry run.",
    });
  }

  // --- Real run. Preflight the things that would otherwise fail identically
  // --- once per membership, so the batch fails fast instead of N times over.
  const url = reminderUrl();
  if (!url) {
    console.error(
      `[${TAG}] CRITICAL: SUPABASE_URL is not set; cannot reach ${REMINDER_FUNCTION}.`,
    );
    return json({ ok: false, error: "reminder_url_not_configured" }, 500);
  }

  const serviceKey = expectedServiceRoleKey();
  if (!serviceKey) {
    return json({ ok: false, error: "service_role_key_not_configured" }, 500);
  }

  if (batch.length === 0) {
    // Not an error, and worth being explicit about: "nothing was due today" is
    // the expected outcome most days for a small gym, and a scheduled job that
    // reported it as a failure would train everyone to ignore its alerts.
    console.log(
      `[${TAG}] nothing due on ${targetDates.join(", ")} — no reminders sent.`,
    );
    return json({
      ...common,
      scanned: 0,
      created: 0,
      reused: 0,
      skipped: 0,
      skipped_by_reason: {},
      errored: 0,
      errored_membership_ids: [],
      errors: [],
      results: [],
      duration_ms: Date.now() - startedAt,
    });
  }

  const delayMs = pickDelay();
  console.log(
    `[${TAG}] scanning ${batch.length} membership(s) due ${targetDates.join(", ")} ` +
      `(offsets ${offsets.join(",")}, delay ${delayMs}ms)`,
  );

  const results: ScanResult[] = [];

  for (let i = 0; i < batch.length; i++) {
    // Sequential on purpose — see pickDelay(). Do NOT turn this into a
    // Promise.all: it would burst N payment-link creations at Razorpay at once.
    if (i > 0 && delayMs > 0) await sleep(delayMs);

    const result = await sendOne(url, serviceKey, batch[i]);
    results.push(result);

    if (result.outcome === "error") {
      // Logged per-failure as well as summarised, so a failure stays greppable
      // in the function logs with its membership id attached.
      console.error(
        `[${TAG}] membership ${result.membership_id} failed: ` +
          `${result.error}${result.detail ? ` (${result.detail})` : ""}`,
      );
    }
  }

  // --- (4) Summary ---
  const skippedByReason: Record<string, number> = {};
  for (const r of results) {
    if (r.outcome === "skipped") {
      const key = r.reason ?? "unspecified";
      skippedByReason[key] = (skippedByReason[key] ?? 0) + 1;
    }
  }

  const count = (o: Outcome) => results.filter((r) => r.outcome === o).length;
  const errors = results.filter((r) => r.outcome === "error");

  const summary = {
    ...common,
    scanned: results.length,
    created: count("created"),
    reused: count("reused"),
    skipped: count("skipped"),
    skipped_by_reason: skippedByReason,
    errored: errors.length,
    errored_membership_ids: errors.map((e) => e.membership_id),
    errors: errors.map((e) => ({
      membership_id: e.membership_id,
      member_name: e.member_name,
      error: e.error,
      detail: e.detail,
      http_status: e.http_status,
    })),
    results,
    duration_ms: Date.now() - startedAt,
  };

  console.log(
    `[${TAG}] done: ${summary.created} created, ${summary.reused} reused, ` +
      `${summary.skipped} skipped, ${summary.errored} errored ` +
      `in ${summary.duration_ms}ms`,
  );

  if (truncated) {
    console.warn(
      `[${TAG}] batch truncated at limit=${limit}. Tomorrow's run will NOT pick ` +
        "these up — they will have moved past the offset by then. Re-run now " +
        "with a higher limit.",
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
    return await handleScan(req);
  } catch (err) {
    // A 5xx here means the SCAN broke (the membership query failed), not that an
    // individual reminder did — those are collected into `errors` and still
    // return 200. pg_cron's stored response is the only place this surfaces, so
    // it has to be loud.
    console.error(`[${TAG}] unhandled failure:`, err);
    return json({
      ok: false,
      error: "internal_error",
      detail: err instanceof Error ? err.message : String(err),
    }, 500);
  }
});
