// send-renewal-reminder — create a renewal payment link and remind the member.
//
// POST { "membership_id": "<uuid>" }
//
// Called once per due membership by renewal-scan (built next), and directly by
// curl for testing. This function is the PRODUCER for razorpay-webhook: the
// `payments` row it writes — status 'pending', razorpay_link_id set,
// provider_payment_id NULL — is exactly the shape that function reconciles
// against when the member pays.
//
// ============================================================================
// WHAT IS REAL
// ============================================================================
// REAL: the Razorpay Payment Links API (POST /v1/payment_links) using
//       RAZORPAY_KEY_ID / RAZORPAY_KEY_SECRET. Test mode is fully functional,
//       so the same code path runs in production and every link this function
//       returns is a real link at Razorpay.
//
// REAL: the outbound WhatsApp send, via the shared helper in
//       ../_shared/whatsapp.ts — a real call to Meta's Cloud API, using the
//       APPROVED renewal_reminder template (language "en_GB" — Meta's code
//       for "English (UK)"). Confirmed in production: the free-form text this
//       used to send fails outside Meta's 24h customer-service window
//       ("more than 24 hours have passed since the customer last replied"),
//       which is why a template is required here. WHATSAPP_SEND_MODE=mock
//       skips the real call; this function's test.sh enforces that for
//       automated runs.
//         rg 'TODO\((meta|razorpay)\)' supabase/functions
//
// ============================================================================
// TWO LAYERS OF IDEMPOTENCY — they guard different things
// ============================================================================
// 1. ONE REMINDER PER MEMBER PER DAY (whatsapp_messages lookback). Stops
//    renewal-scan spamming a member if it is accidentally run twice in a day.
//    This is the messaging guard.
//
// 2. ONE PAYMENT ROW PER RENEWAL PERIOD (payments.idempotency_key UNIQUE, and
//    the derived Razorpay reference_id). Stops a second charge existing for the
//    same period even across days — day 7 and day 3 reminders for the same
//    renewal reuse ONE payments row and ONE payment link. This is the money
//    guard, and it is why the reminder can be re-sent tomorrow without
//    creating a second link.
//
// Unlike the two webhook functions there is no webhook_events row here: this
// function is not triggered by an external provider, so there is no external
// event id to de-duplicate on.
// ============================================================================

import "@supabase/functions-js/edge-runtime.d.ts";
import { createAdminClient, type SupabaseClient } from "../_shared/supabase.ts";
import { sha256Hex } from "../_shared/crypto.ts";
import { authorizeServiceRole } from "../_shared/auth.ts";
import { sendWhatsAppMessage } from "../_shared/whatsapp.ts";

const TAG = "send-renewal-reminder";
const PROVIDER = "razorpay" as const;
const TEMPLATE_NAME = "renewal_reminder" as const;
// Meta's locale code for the template's registered language, "English (UK)" —
// not plain "en", which is a different template language variant to Meta.
const TEMPLATE_LANGUAGE = "en_GB" as const;
const RAZORPAY_API = "https://api.razorpay.com/v1/payment_links";

// The once-per-day guard needs a timezone to mean anything. Same default and
// same reasoning as BILLING_TIMEZONE in razorpay-webhook: for a gym in IST, a
// UTC day boundary falls at 05:30 local, so an early-morning cron run would
// straddle two "days" and be allowed to send twice.
//
// NOTE: this is the timezone-correct form of the spec'd predicate
// `date_trunc('day', created_at) = date_trunc('day', now())`. PostgREST runs
// with TimeZone=UTC, so that expression would have compared UTC days; the
// half-open [start_of_local_day, start_of_next_local_day) range below is the
// same comparison done in the gym's timezone instead. Set REMINDER_TIMEZONE=UTC
// to get the literal UTC-day behaviour back.
const REMINDER_TIMEZONE = Deno.env.get("REMINDER_TIMEZONE") ??
  Deno.env.get("BILLING_TIMEZONE") ?? "Asia/Kolkata";

// One round trip gets the membership, the member to message, and the plan price.
const MEMBERSHIP_SELECT =
  "id,organization_id,member_id,plan_id,status,current_period_end,duration_months," +
  "members(id,name,phone,whatsapp_opt_in)," +
  "membership_plans(id,name,amount)";

const PAYMENT_SELECT =
  "id,organization_id,membership_id,amount,status,razorpay_link_id," +
  "provider_payment_id,idempotency_key";

const MESSAGE = {
  renewalReminder: (
    name: string,
    plan: string,
    renewsOn: string,
    url: string,
  ) =>
    `Hi ${name}, your ${plan} membership renews on ${renewsOn}. ` +
    `Pay here to continue: ${url}`,
} as const;

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
  duration_months: number;
  members: {
    id: string;
    name: string;
    phone: string;
    whatsapp_opt_in: boolean;
  } | null;
  membership_plans: {
    id: string;
    name: string;
    amount: number | string;
  } | null;
}

interface PaymentRow {
  id: string;
  organization_id: string;
  membership_id: string;
  amount: number | string;
  status: string;
  razorpay_link_id: string | null;
  provider_payment_id: string | null;
  idempotency_key: string;
}

interface PaymentLink {
  id: string;
  short_url: string;
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

/** Same member-facing date format as razorpay-webhook: "12 Sep 2026". */
function formatDateForMember(isoDate: string): string {
  const [year, month, day] = isoDate.split("-").map(Number);
  return new Intl.DateTimeFormat("en-IN", {
    day: "numeric",
    month: "short",
    year: "numeric",
    timeZone: "UTC",
  }).format(new Date(Date.UTC(year, month - 1, day)));
}

/**
 * The half-open timestamptz range covering "today" in REMINDER_TIMEZONE,
 * as ISO strings suitable for a PostgREST gte/lt filter pair.
 *
 * Derives the zone's current UTC offset by formatting `now` in that zone and
 * reading the offset back, so DST-observing zones stay correct without a tzdata
 * dependency (IST has no DST, but this function should not be the reason a
 * future non-IST tenant breaks).
 */
function localDayWindow(timeZone: string): { start: string; end: string } {
  const now = new Date();

  const parts = new Intl.DateTimeFormat("en-CA", {
    timeZone,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
    hourCycle: "h23",
  }).formatToParts(now);

  const get = (type: string) => Number(parts.find((p) => p.type === type)!.value);

  // Midnight of the local day, expressed as if the local wall clock were UTC.
  const localMidnightAsUtc = Date.UTC(get("year"), get("month") - 1, get("day"));
  // The wall-clock instant we formatted, same trick — the difference between
  // this and `now` is the zone's offset at this moment.
  const localNowAsUtc = localMidnightAsUtc +
    (get("hour") * 3600 + get("minute") * 60 + get("second")) * 1000;
  const offsetMs = localNowAsUtc - now.getTime();

  const start = localMidnightAsUtc - offsetMs;

  return {
    start: new Date(start).toISOString(),
    end: new Date(start + 24 * 60 * 60 * 1000).toISOString(),
  };
}

/**
 * Rupees → integer paise. membership_plans.amount is NUMERIC(10,2) in rupees
 * (1500.00 = ₹1500) and Razorpay wants integer paise, so 1500.00 → 150000.
 * Math.round, not truncation: 1499.99 * 100 is 149998.99999... in float.
 */
function rupeesToPaise(amount: number): number {
  return Math.round(amount * 100);
}

// ---------------------------------------------------------------------------
// Caller authentication
//
// This endpoint spends real money-side resources (it creates live payment
// links) and sends member-facing messages, so `verify_jwt = true` in
// config.toml is necessary but NOT sufficient: it accepts the ANON key too, and
// the anon key is public in any client app. That would let anyone POST
// arbitrary membership_ids.
//
// So we additionally require the caller to present the SERVICE ROLE key —
// which is what renewal-scan (function-to-function) and curl-based testing use
// anyway. Not a signature scheme like the webhooks use, because there is no
// external provider here signing anything: the only legitimate callers are
// already trusted holders of the service key.
// The check itself now lives in ../_shared/auth.ts as authorizeServiceRole(),
// shared with renewal-scan, daily-owner-brief and mark-overdue. It was inlined
// here first, before that file existed; the two were behaviourally identical
// (same env-var precedence, same bearer/apikey fallback, same constant-time
// compare, same three-way verdict), so this is an implementation change only.
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Razorpay Payment Links — REAL, not simulated
// ---------------------------------------------------------------------------

function razorpayAuthHeader(): string | null {
  const keyId = Deno.env.get("RAZORPAY_KEY_ID");
  const keySecret = Deno.env.get("RAZORPAY_KEY_SECRET");

  if (!keyId || !keySecret) return null;

  return `Basic ${btoa(`${keyId}:${keySecret}`)}`;
}

/**
 * Razorpay's reference_id is capped at 40 characters, so the full
 * idempotency_key ("renewal-<uuid>-<date>", 55 chars) will not fit. A truncated
 * SHA-256 keeps it deterministic — that is the whole point: it lets us find a
 * link we already created but failed to record, via
 * GET /v1/payment_links?reference_id=...
 */
async function referenceIdFor(idempotencyKey: string): Promise<string> {
  return `rnw_${(await sha256Hex(idempotencyKey)).slice(0, 32)}`;
}

class RazorpayError extends Error {
  constructor(
    message: string,
    readonly httpStatus: number,
    readonly alreadyExists: boolean,
  ) {
    super(message);
  }
}

/**
 * Create a real payment link.
 *
 * `notes` carries our own identifiers into Razorpay and back out on every
 * webhook for this payment. See the DECISION POINT note at the bottom of this
 * file: these notes are what would make a last-resort webhook lookup possible
 * for a payload that carries neither a link id nor a known payment id.
 */
async function createPaymentLink(
  authHeader: string,
  params: {
    amountPaise: number;
    description: string;
    customerName: string;
    customerContact: string;
    referenceId: string;
    organizationId: string;
    membershipId: string;
    idempotencyKey: string;
  },
): Promise<PaymentLink> {
  const payload = JSON.stringify({
    amount: params.amountPaise,
    currency: "INR",
    description: params.description,
    reference_id: params.referenceId,
    customer: {
      name: params.customerName,
      contact: params.customerContact,
    },
    // We send the WhatsApp message ourselves — letting Razorpay notify too
    // would double-message the member.
    notify: { sms: false, email: false, whatsapp: false },
    notes: {
      organization_id: params.organizationId,
      membership_id: params.membershipId,
      idempotency_key: params.idempotencyKey,
    },
  });

  // -------------------------------------------------------------------------
  // RETRY ON RATE LIMIT — a 429 is not a failure, it is a "wait"
  // -------------------------------------------------------------------------
  // Found by running every suite back to back: Razorpay answered "Too many
  // requests" partway through a renewal-scan batch. Everything downstream
  // behaved correctly — the scan caught it, reported it and carried on — but
  // the OUTCOME was wrong: renewal-scan records a razorpay_error as terminal,
  // so that member simply got no reminder, and would not get one until the next
  // day's scan. A transient throttle should never cost someone a renewal notice.
  //
  // Retried here rather than in renewal-scan because this is the layer that
  // knows the failure was transient, and because a retry at this depth re-does
  // only the HTTP call — the membership lookup, the idempotency key and the
  // reference_id are all already computed and unchanged, so a retry is exactly
  // the same request and cannot create a second link.
  //
  // Bounded deliberately: two extra attempts, ~700ms then ~1500ms. Long enough
  // to clear a short burst, short enough that a genuinely rate-limited batch
  // fails fast instead of holding the invocation open until the wall clock
  // kills it (which would lose the summary for every membership after it).
  // Only 429 and Razorpay-side 5xx are retried; a 400 is our bug and repeating
  // it just wastes the budget.
  const RETRY_DELAYS_MS = [700, 1500, 3000];
  let res!: Response;
  let body: any = null;

  for (let attempt = 0; ; attempt++) {
    res = await fetch(RAZORPAY_API, {
      method: "POST",
      headers: {
        authorization: authHeader,
        "content-type": "application/json",
      },
      body: payload,
    });

    body = await res.json().catch(() => null);

    const description: string = body?.error?.description ?? "";
    const throttled = res.status === 429 || /too many requests/i.test(description);
    const upstreamFault = res.status >= 500;

    if (res.ok || attempt >= RETRY_DELAYS_MS.length || !(throttled || upstreamFault)) {
      break;
    }

    const wait = RETRY_DELAYS_MS[attempt];
    console.warn(
      `[${TAG}] Razorpay ${res.status}${description ? ` (${description})` : ""} ` +
        `creating link for ${params.referenceId}; retrying in ${wait}ms ` +
        `(attempt ${attempt + 2}/${RETRY_DELAYS_MS.length + 1}).`,
    );
    await new Promise((r) => setTimeout(r, wait));
  }

  if (!res.ok) {
    const description: string = body?.error?.description ?? "unknown error";
    // Razorpay enforces reference_id uniqueness per account and answers 400
    // with "...already exists...". That is a SUCCESS signal for us: a previous
    // run created this link and died before writing the payments row.
    throw new RazorpayError(
      description,
      res.status,
      /already exists/i.test(description),
    );
  }

  return { id: body.id, short_url: body.short_url };
}

/** Recover a link we may have created but failed to record. */
async function fetchPaymentLinkByReference(
  authHeader: string,
  referenceId: string,
): Promise<PaymentLink | null> {
  const res = await fetch(
    `${RAZORPAY_API}?reference_id=${encodeURIComponent(referenceId)}`,
    { headers: { authorization: authHeader } },
  );

  if (!res.ok) {
    console.error(`[${TAG}] Razorpay link lookup by reference failed`, res.status);
    return null;
  }

  const body = await res.json().catch(() => null);
  const links = Array.isArray(body?.payment_links) ? body.payment_links : [];

  if (links.length === 0) return null;

  return { id: links[0].id, short_url: links[0].short_url };
}

/**
 * Re-read short_url for a link we already have the id of. payments has no
 * column for short_url, so a reminder re-sent on a later day has to ask
 * Razorpay for the URL again rather than inventing a second link.
 */
async function fetchPaymentLinkById(
  authHeader: string,
  linkId: string,
): Promise<PaymentLink | null> {
  const res = await fetch(`${RAZORPAY_API}/${encodeURIComponent(linkId)}`, {
    headers: { authorization: authHeader },
  });

  if (!res.ok) {
    console.error(`[${TAG}] Razorpay link fetch ${linkId} failed`, res.status);
    return null;
  }

  const body = await res.json().catch(() => null);
  if (!body?.id || !body?.short_url) return null;

  return { id: body.id, short_url: body.short_url };
}

// ---------------------------------------------------------------------------
// Database reads
// ---------------------------------------------------------------------------

async function loadMembership(
  supabase: SupabaseClient,
  membershipId: string,
): Promise<MembershipRow | null> {
  const { data, error } = await supabase
    .from("memberships")
    .select(MEMBERSHIP_SELECT)
    .eq("id", membershipId)
    .maybeSingle();

  if (error) throw error;

  return (data as MembershipRow | null) ?? null;
}

/**
 * Guard #1: has this member already had a renewal reminder today?
 *
 * Scoped by organization_id as well as member_id — members.id is a UUID PK so
 * member_id alone is unambiguous, but every service-role query in this project
 * scopes by tenant on purpose (see ../_shared/supabase.ts).
 */
async function alreadySentToday(
  supabase: SupabaseClient,
  organizationId: string,
  memberId: string,
): Promise<boolean> {
  const { start, end } = localDayWindow(REMINDER_TIMEZONE);

  const { data, error } = await supabase
    .from("whatsapp_messages")
    .select("id")
    .eq("organization_id", organizationId)
    .eq("member_id", memberId)
    .eq("direction", "outbound")
    .eq("template_name", TEMPLATE_NAME)
    .gte("created_at", start)
    .lt("created_at", end)
    .limit(1);

  if (error) throw error;

  return (data ?? []).length > 0;
}

async function findPaymentByIdempotencyKey(
  supabase: SupabaseClient,
  organizationId: string,
  idempotencyKey: string,
): Promise<PaymentRow | null> {
  const { data, error } = await supabase
    .from("payments")
    .select(PAYMENT_SELECT)
    .eq("organization_id", organizationId)
    .eq("idempotency_key", idempotencyKey)
    .maybeSingle();

  if (error) throw error;

  return (data as PaymentRow | null) ?? null;
}

// ---------------------------------------------------------------------------
// Main flow
// ---------------------------------------------------------------------------

async function handleReminder(req: Request): Promise<Response> {
  // --- Parse input ---
  let body: any;
  try {
    body = await req.json();
  } catch {
    return json({ ok: false, error: "invalid_json_body" }, 400);
  }

  const membershipId = typeof body?.membership_id === "string"
    ? body.membership_id.trim()
    : "";

  if (!membershipId) {
    return json({
      ok: false,
      error: "membership_id_required",
      detail: 'POST body must be { "membership_id": "<uuid>" }',
    }, 400);
  }

  // Postgres rejects a malformed uuid with 22P02, which would otherwise surface
  // as a confusing 500 on a plain typo.
  if (
    !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
      .test(membershipId)
  ) {
    return json({
      ok: false,
      error: "membership_id_malformed",
      detail: `not a uuid: ${membershipId}`,
    }, 400);
  }

  const supabase = createAdminClient();

  // --- (a) Look up the membership, member and plan in one round trip ---
  // A pure read, so it is safe to do before the guards; nothing below this
  // point has a side effect until the Razorpay call.
  const membership = await loadMembership(supabase, membershipId);

  if (!membership) {
    console.warn(`[${TAG}] membership ${membershipId} not found`);
    return json({ ok: false, error: "membership_not_found", membership_id: membershipId }, 404);
  }

  const member = membership.members;
  const plan = membership.membership_plans;

  // memberships.member_id and .plan_id are both NOT NULL with FKs, so this is
  // defensive only — it would mean a missing GRANT or a broken embed, not bad data.
  if (!member || !plan) {
    console.error(
      `[${TAG}] membership ${membershipId} loaded without ` +
        `${!member ? "member" : "plan"} — check GRANTs on members/membership_plans.`,
    );
    return json({ ok: false, error: "membership_incomplete" }, 500);
  }

  // --- (b) Guard #1: one renewal reminder per member per day ---
  if (await alreadySentToday(supabase, membership.organization_id, member.id)) {
    console.log(
      `[${TAG}] member ${member.id} already got a renewal reminder today — skipping.`,
    );
    return json({ ok: true, skipped: "already_sent_today" });
  }

  // --- (c) Guard #2: never message a member who has not opted in ---
  if (!member.whatsapp_opt_in) {
    console.log(`[${TAG}] member ${member.id} has whatsapp_opt_in=false — skipping.`);
    return json({
      ok: true,
      skipped: "whatsapp_opt_out",
      membership_id: membership.id,
      member_id: member.id,
    });
  }

  // NOTE: membership.status is deliberately NOT gated here. Deciding who is due
  // — and whether a 'cancelled' or 'expired' membership should still be chased
  // — is renewal-scan's dunning policy, and this function must stay callable for
  // whatever that policy selects. Status is echoed in the response so the caller
  // can see what it acted on.

  const authHeader = razorpayAuthHeader();
  if (!authHeader) {
    console.error(
      `[${TAG}] CRITICAL: RAZORPAY_KEY_ID / RAZORPAY_KEY_SECRET not set. ` +
        "Set them with: supabase secrets set RAZORPAY_KEY_ID=... RAZORPAY_KEY_SECRET=...",
    );
    return json({ ok: false, error: "razorpay_not_configured" }, 500);
  }

  // --- (d) Deterministic keys for this renewal period ---
  const idempotencyKey =
    `renewal-${membership.id}-${membership.current_period_end}`;
  const referenceId = await referenceIdFor(idempotencyKey);

  const monthlyRupees = Number(plan.amount);
  if (!Number.isFinite(monthlyRupees) || monthlyRupees <= 0) {
    console.error(
      `[${TAG}] plan ${plan.id} has a non-chargeable amount: ${plan.amount}`,
    );
    return json({ ok: false, error: "plan_amount_invalid" }, 500);
  }
  // A renewal renews for the membership's full committed duration, so the
  // charge is the monthly rate x duration_months (1 for legacy monthly
  // signups). See 20260829099000_move_duration_to_memberships.sql — duration
  // is a property of the signup, not the plan.
  const amountRupees = monthlyRupees * (membership.duration_months ?? 1);

  // --- (e) Reuse an existing payments row for this period if there is one ---
  // Checked BEFORE calling Razorpay so the ordinary repeat case (a second
  // reminder for the same renewal on a later day) does not create a second live
  // payment link. The unique-violation handler further down is only the
  // concurrent-caller backstop.
  const existing = await findPaymentByIdempotencyKey(
    supabase,
    membership.organization_id,
    idempotencyKey,
  );

  let payment: PaymentRow;
  let link: PaymentLink;
  let outcome: "created" | "reused";

  if (existing) {
    // Already paid: asking again would be wrong, and razorpay-webhook has
    // already extended the period.
    if (existing.status === "success") {
      console.log(
        `[${TAG}] payment ${existing.id} for this period is already 'success' — skipping.`,
      );
      return json({
        ok: true,
        skipped: "already_paid",
        payment_id: existing.id,
        membership_id: membership.id,
      });
    }

    const recovered = existing.razorpay_link_id
      ? await fetchPaymentLinkById(authHeader, existing.razorpay_link_id)
      : await fetchPaymentLinkByReference(authHeader, referenceId);

    if (!recovered) {
      // We have a payments row we cannot attach a URL to. Creating a fresh link
      // would be worse: this function only holds SELECT/INSERT on payments (see
      // the grants migration), so it could not record the new link id, and
      // razorpay-webhook would then fail to match the payment the member made.
      // Surfaced loudly instead of papered over.
      console.error(
        `[${TAG}] payments row ${existing.id} exists (status=${existing.status}, ` +
          `razorpay_link_id=${existing.razorpay_link_id}) but no matching ` +
          "Razorpay link could be recovered. Reconcile manually.",
      );
      return json({
        ok: false,
        error: "payment_link_unrecoverable",
        payment_id: existing.id,
        razorpay_link_id: existing.razorpay_link_id,
      }, 502);
    }

    payment = existing;
    link = recovered;
    outcome = "reused";

    console.log(
      `[${TAG}] reusing payment ${payment.id} / link ${link.id} for ${idempotencyKey}`,
    );
  } else {
    // --- Create the real payment link ---
    try {
      link = await createPaymentLink(authHeader, {
        amountPaise: rupeesToPaise(amountRupees),
        description: plan.name,
        customerName: member.name,
        customerContact: member.phone,
        referenceId,
        organizationId: membership.organization_id,
        membershipId: membership.id,
        idempotencyKey,
      });
    } catch (err) {
      if (err instanceof RazorpayError && err.alreadyExists) {
        // A previous run created the link and died before the DB insert.
        // Deterministic reference_id makes it findable — that is why we set it.
        console.warn(
          `[${TAG}] link for ${referenceId} already exists at Razorpay; recovering it.`,
        );
        const recovered = await fetchPaymentLinkByReference(authHeader, referenceId);

        if (!recovered) {
          return json({
            ok: false,
            error: "razorpay_link_orphaned",
            detail: `reference_id ${referenceId} exists but could not be fetched`,
          }, 502);
        }
        link = recovered;
      } else {
        const detail = err instanceof Error ? err.message : String(err);
        console.error(`[${TAG}] Razorpay payment link creation failed:`, detail);
        return json({ ok: false, error: "razorpay_error", detail }, 502);
      }
    }

    // --- (e) Insert the payments row razorpay-webhook will reconcile ---
    const { data: inserted, error: insertError } = await supabase
      .from("payments")
      .insert({
        organization_id: membership.organization_id,
        membership_id: membership.id,
        amount: amountRupees,
        provider: PROVIDER,
        razorpay_link_id: link.id,
        // Left NULL on purpose: razorpay-webhook backfills it from the
        // payment.captured / payment_link.paid payload. Until then
        // razorpay_link_id is the ONLY handle it can match on.
        provider_payment_id: null,
        status: "pending",
        idempotency_key: idempotencyKey,
      })
      .select(PAYMENT_SELECT)
      .single();

    if (insertError) {
      // 23505 = unique_violation on payments.idempotency_key. Two callers raced
      // for the same renewal; the other one won.
      if (insertError.code === "23505") {
        const winner = await findPaymentByIdempotencyKey(
          supabase,
          membership.organization_id,
          idempotencyKey,
        );

        if (!winner) throw insertError;

        // The link we just created is now an orphan at Razorpay. Send the
        // WINNER's link, not ours, or the member would pay a link whose id is
        // in no payments row and razorpay-webhook could not reconcile it.
        console.warn(
          `[${TAG}] lost the race for ${idempotencyKey}; payments row ` +
            `${winner.id} already exists. Link ${link.id} is orphaned at ` +
            "Razorpay (harmless: unpaid, unsent) — cancel it there if you care.",
        );

        const winnerLink = winner.razorpay_link_id === link.id
          ? link
          : (winner.razorpay_link_id
            ? await fetchPaymentLinkById(authHeader, winner.razorpay_link_id)
            : null);

        if (!winnerLink) {
          return json({
            ok: false,
            error: "payment_link_unrecoverable",
            payment_id: winner.id,
          }, 502);
        }

        payment = winner;
        link = winnerLink;
        outcome = "reused";
      } else {
        throw insertError;
      }
    } else {
      payment = inserted as PaymentRow;
      outcome = "created";
      console.log(
        `[${TAG}] created payment ${payment.id} link=${link.id} ` +
          `amount=₹${amountRupees} key=${idempotencyKey}`,
      );
    }
  }

  // --- (f)+(g) "Send" the reminder and log it ---
  const text = MESSAGE.renewalReminder(
    member.name,
    plan.name,
    formatDateForMember(membership.current_period_end),
    link.short_url,
  );

  const send = await sendWhatsAppMessage(supabase, member.phone, text, {
    tag: TAG,
    memberId: member.id,
    organizationId: membership.organization_id,
    templateName: TEMPLATE_NAME,
    relatedPaymentId: payment.id,
  }, {
    name: TEMPLATE_NAME,
    language: TEMPLATE_LANGUAGE,
    // Same order as the template body: "Hi {{1}}, your {{2}} membership
    // renews on {{3}}. Pay here: {{4}}. Reply PAY if you need help."
    bodyParams: [
      member.name,
      plan.name,
      formatDateForMember(membership.current_period_end),
      link.short_url,
    ],
  });

  if (!send.logged) {
    // The whatsapp_messages row IS guard #1, so without it a re-run today would
    // message the member again (it would reuse the same payment link, so no
    // duplicate charge is possible). Reported rather than swallowed.
    console.error(
      `[${TAG}] reminder for member ${member.id} was not logged — the ` +
        "once-per-day guard cannot see it.",
    );
  }

  return json({
    ok: true,
    [outcome]: true,
    membership_id: membership.id,
    membership_status: membership.status,
    member_id: member.id,
    organization_id: membership.organization_id,
    payment_id: payment.id,
    razorpay_link_id: link.id,
    payment_url: link.short_url,
    amount: amountRupees,
    idempotency_key: idempotencyKey,
    current_period_end: membership.current_period_end,
    whatsapp_message_id: send.messageId,
    whatsapp_message_logged: send.logged,
    body_preview: text,
  });
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
    return await handleReminder(req);
  } catch (err) {
    // Unlike the webhooks, a 5xx here is CORRECT: the caller is renewal-scan,
    // which should see the failure, log it and retry this membership later.
    // Nothing is half-written that a retry cannot converge on — the payments
    // row is keyed on idempotency_key and the link on reference_id.
    console.error(`[${TAG}] unhandled failure:`, err);
    return json({
      ok: false,
      error: "internal_error",
      detail: err instanceof Error ? err.message : String(err),
    }, 500);
  }
});

/* ===========================================================================
 * DECISION POINT for razorpay-webhook (NOT changed — review separately)
 * ===========================================================================
 * The gap found in manual testing: a `payment.failed` for a payment that never
 * came from a payment link arrives with no link id, and its payment id is not
 * in `payments` yet, so findPaymentRow() matches nothing.
 *
 * A fallback of "organization_id + membership_id + status='pending'" cannot be
 * implemented as stated, because such a payload contains NEITHER of those
 * columns — there is nothing to derive them from. It would collapse to "newest
 * pending payment", which is a guess, and guessing wrong marks an unrelated
 * payment 'failed'.
 *
 * That is why createPaymentLink() above sends `notes`:
 *   notes: { organization_id, membership_id, idempotency_key }
 * Razorpay echoes a link's notes onto the payment created from it and back into
 * every webhook for that payment, so the identifiers ARE present in the payload
 * for anything that originated here. The recommended fallback is therefore an
 * exact lookup on notes, not a heuristic:
 *
 *   const notes = body?.payload?.payment?.entity?.notes;
 *   if (notes?.idempotency_key) -> payments.eq('idempotency_key', ...)   // exact
 *   else if (notes?.membership_id) -> payments
 *     .eq('organization_id', notes.organization_id)
 *     .eq('membership_id', notes.membership_id)
 *     .eq('status', 'pending')
 *     .order('created_at', {ascending:false}).limit(1)                   // scoped
 *
 * Payments with no notes at all (a Razorpay dashboard link, a Payment Pages
 * collection, a direct API charge) are genuinely un-attributable and should
 * keep hitting the existing "NO MATCHING PAYMENTS ROW" error log — that log is
 * the correct outcome, not a bug to fix.
 * ======================================================================== */
