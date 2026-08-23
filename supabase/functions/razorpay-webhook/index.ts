// razorpay-webhook — Razorpay payment webhook receiver.
//
// Reconciles payments against `payments`, extends the paid membership period,
// and notifies the member on WhatsApp.
//
// ============================================================================
// WHAT IS REAL AND WHAT IS SIMULATED
// ============================================================================
// REAL: signature verification (HMAC-SHA256 over the raw body, keyed on
//       RAZORPAY_WEBHOOK_SECRET). Razorpay test mode is fully functional, so
//       there is nothing to stub here — the same code path runs in production.
//
// SIMULATED: the outbound WhatsApp send, exactly as in whatsapp-webhook. It
//       console.log()s and writes a whatsapp_messages row with status 'queued'.
//       The swap point uses the identical BEGIN/END SIMULATED SEND fence, so
//       both functions are updated the same way when Meta credentials land:
//         rg 'BEGIN SIMULATED SEND' supabase/functions
//
// Grep the temporary surface with:
//   rg 'TODO\((meta|razorpay)\)' supabase/functions
// ============================================================================

import "@supabase/functions-js/edge-runtime.d.ts";
import { createAdminClient, type SupabaseClient } from "../_shared/supabase.ts";
import { hmacSha256Hex, timingSafeEqualHex } from "../_shared/crypto.ts";

const SOURCE = "razorpay" as const;
const SIGNATURE_HEADER = "x-razorpay-signature";
const EVENT_ID_HEADER = "x-razorpay-event-id";

// current_period_end is a DATE, so "today" needs a timezone to be meaningful.
// Defaults to the same zone as locations.timezone in the schema; a gym in IST
// rolling over at UTC midnight would otherwise bill a day early.
// TODO: derive this per-location from locations.timezone once a payment can be
// attributed to a specific location.
const BILLING_TIMEZONE = Deno.env.get("BILLING_TIMEZONE") ?? "Asia/Kolkata";

// Razorpay events we act on. Anything else is acked and ignored (forward-compatible).
const SUCCESS_EVENTS = ["payment.captured", "payment_link.paid"];
const FAILURE_EVENTS = ["payment.failed"];

const MESSAGE = {
  paymentReceived: (until: string) =>
    `Payment received! ✅ Your membership is active until ${until}.`,
  paymentFailed:
    "We couldn't process your payment. Reply PAY to try again or contact your gym.",
} as const;

// One round trip gets the payment, its membership, and the member to notify.
const PAYMENT_SELECT =
  "id,organization_id,membership_id,amount,status,provider_payment_id,razorpay_link_id," +
  "memberships(id,member_id,status,current_period_end,members(id,name,phone))";

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

interface ExtractedPayment {
  razorpayPaymentId: string | null;
  razorpayLinkId: string | null;
  /** Rupees. Razorpay sends paise; see extractPayment(). */
  amount: number | null;
  /**
   * Our own identifiers, echoed back by Razorpay. send-renewal-reminder writes
   * these onto every payment link it creates; Razorpay carries a link's notes
   * onto the payment made from it and into every webhook for that payment.
   * See the lookup tiers in findPaymentRow().
   */
  notes: {
    organizationId: string | null;
    membershipId: string | null;
    idempotencyKey: string | null;
  };
}

interface PaymentRow {
  id: string;
  organization_id: string;
  membership_id: string;
  amount: number | string;
  status: string;
  provider_payment_id: string | null;
  razorpay_link_id: string | null;
  memberships: {
    id: string;
    member_id: string;
    status: string;
    current_period_end: string;
    members: { id: string; name: string; phone: string } | null;
  } | null;
}

type MatchedBy =
  | "provider_payment_id"
  | "razorpay_link_id"
  | "notes_idempotency_key"
  | "notes_membership_id";

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

/** Today as YYYY-MM-DD in the billing timezone. en-CA formats as ISO. */
function todayInBillingTimezone(): string {
  return new Intl.DateTimeFormat("en-CA", {
    timeZone: BILLING_TIMEZONE,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).format(new Date());
}

/**
 * Add one calendar month to a YYYY-MM-DD string, clamping to the end of the
 * target month — the same semantics as Postgres `date + interval '1 month'`
 * (2026-01-31 → 2026-02-28). Naive `Date.setMonth()` would overflow to March 3
 * and silently hand out three extra days.
 *
 * TODO: membership_plans.billing_interval is CHECK-constrained to 'monthly'
 * today. When quarterly/annual plans arrive, read the interval from the plan
 * and generalise this.
 */
function addOneMonth(isoDate: string): string {
  const [year, month, day] = isoDate.split("-").map(Number);

  const targetYear = year + Math.floor(month / 12);
  const targetMonth = (month % 12) + 1;

  // Day 0 of the following month is the last day of the target month.
  const lastDayOfTarget = new Date(Date.UTC(targetYear, targetMonth, 0))
    .getUTCDate();
  const clampedDay = Math.min(day, lastDayOfTarget);

  return [
    String(targetYear).padStart(4, "0"),
    String(targetMonth).padStart(2, "0"),
    String(clampedDay).padStart(2, "0"),
  ].join("-");
}

/** Lexical compare is correct for zero-padded ISO dates. */
function laterDate(a: string, b: string): string {
  return a >= b ? a : b;
}

function formatDateForMember(isoDate: string): string {
  const [year, month, day] = isoDate.split("-").map(Number);
  return new Intl.DateTimeFormat("en-IN", {
    day: "numeric",
    month: "short",
    year: "numeric",
    timeZone: "UTC",
  }).format(new Date(Date.UTC(year, month - 1, day)));
}

// ---------------------------------------------------------------------------
// Signature verification — REAL, not simulated
// ---------------------------------------------------------------------------

type SignatureVerdict = "ok" | "invalid" | "misconfigured";

async function verifyRazorpaySignature(
  req: Request,
  rawBody: string,
): Promise<SignatureVerdict> {
  const secret = Deno.env.get("RAZORPAY_WEBHOOK_SECRET");

  if (!secret) {
    // Deliberately NOT treated as a signature failure. A 400 would make
    // Razorpay give up on genuine events because of our own misconfiguration;
    // a 5xx makes it retry, so events survive until the secret is set.
    console.error(
      "[razorpay-webhook] CRITICAL: RAZORPAY_WEBHOOK_SECRET is not set. " +
        "Cannot verify any webhook. Set it with: supabase secrets set RAZORPAY_WEBHOOK_SECRET=...",
    );
    return "misconfigured";
  }

  const provided = req.headers.get(SIGNATURE_HEADER);
  if (!provided) return "invalid";

  const expected = await hmacSha256Hex(secret, rawBody);

  // Razorpay sends a bare lowercase hex digest — no "sha256=" prefix, unlike Meta.
  return timingSafeEqualHex(provided.trim().toLowerCase(), expected)
    ? "ok"
    : "invalid";
}

// ---------------------------------------------------------------------------
// Payload extraction
// ---------------------------------------------------------------------------

/**
 * Razorpay's envelope:
 *   { entity: "event", event: "payment.captured", contains: ["payment"],
 *     payload: { payment: { entity: {...} }, payment_link: { entity: {...} } } }
 */
function extractPayment(body: any): ExtractedPayment {
  const payment = body?.payload?.payment?.entity;
  const link = body?.payload?.payment_link?.entity;

  // Razorpay amounts are integer PAISE. payments.amount is NUMERIC(10,2) in
  // rupees (membership_plans.amount is 1500.00 = ₹1500), so divide by 100.
  const paise = payment?.amount ?? link?.amount ?? null;

  // Notes ride on the payment entity for anything created from one of our
  // links; the payment_link entity is the fallback for payment_link.* events
  // where the payment block may be absent.
  const notes = payment?.notes ?? link?.notes ?? null;
  const note = (key: string): string | null =>
    typeof notes?.[key] === "string" && notes[key].length > 0 ? notes[key] : null;

  return {
    razorpayPaymentId: typeof payment?.id === "string" ? payment.id : null,
    razorpayLinkId: typeof link?.id === "string"
      ? link.id
      // payment.captured on a link-originated payment sometimes carries the
      // link id on the payment entity instead of a payment_link block.
      : (typeof payment?.payment_link_id === "string"
        ? payment.payment_link_id
        : null),
    amount: typeof paise === "number" ? paise / 100 : null,
    notes: {
      organizationId: note("organization_id"),
      membershipId: note("membership_id"),
      idempotencyKey: note("idempotency_key"),
    },
  };
}

/**
 * Resolve the idempotency key for this delivery.
 *
 * Razorpay's canonical event id is the `X-Razorpay-Event-Id` header; a
 * top-level `id` is present on some payload versions but not guaranteed. We try
 * both, then fall back to a DETERMINISTIC synthesis so that a retry of the same
 * event still collides on webhook_events (source, event_id) — a random UUID
 * would silently defeat the whole guard.
 */
function resolveEventId(
  req: Request,
  body: any,
): { eventId: string; derivedFrom: string } {
  if (typeof body?.id === "string" && body.id.length > 0) {
    return { eventId: body.id, derivedFrom: "payload.id" };
  }

  const header = req.headers.get(EVENT_ID_HEADER);
  if (header) return { eventId: header, derivedFrom: EVENT_ID_HEADER };

  const anchor = body?.payload?.payment?.entity?.id ??
    body?.payload?.payment_link?.entity?.id;

  if (anchor) {
    return {
      eventId: `${body?.event ?? "unknown"}:${anchor}`,
      derivedFrom: "synthesized(event:entity_id)",
    };
  }

  console.warn(
    "[razorpay-webhook] no event id and no entity to synthesize one from — " +
      "this delivery cannot be de-duplicated.",
  );
  return {
    eventId: `unidentified:${crypto.randomUUID()}`,
    derivedFrom: "random(NOT idempotent)",
  };
}

// ===========================================================================
// OUTBOUND MESSAGING — THE ONE PLACE TO SWAP IN THE REAL META API
// ===========================================================================

/**
 * "Send" a WhatsApp message to `phone`.
 *
 * TODO(meta): SIMULATED, identical to the helper in whatsapp-webhook. When Meta
 * credentials land, replace the fenced block below in BOTH functions.
 */
async function sendWhatsAppMessage(
  supabase: SupabaseClient,
  phone: string | null,
  text: string,
  context: {
    memberId?: string | null;
    organizationId?: string | null;
    templateName?: string | null;
    relatedPaymentId?: string | null;
  } = {},
): Promise<void> {
  let waMessageId: string | null = null;
  let status: "queued" | "sent" | "failed" = "queued";

  // ---------------- BEGIN SIMULATED SEND — REPLACE THIS BLOCK ----------------
  // TODO(meta): swap the console.log for the real Cloud API call:
  //
  //   const res = await fetch(
  //     `https://graph.facebook.com/v21.0/${Deno.env.get("META_PHONE_NUMBER_ID")}/messages`,
  //     {
  //       method: "POST",
  //       headers: {
  //         authorization: `Bearer ${Deno.env.get("META_ACCESS_TOKEN")}`,
  //         "content-type": "application/json",
  //       },
  //       body: JSON.stringify({
  //         messaging_product: "whatsapp",
  //         recipient_type: "individual",
  //         to: phone,
  //         type: "text",
  //         text: { preview_url: false, body: text },
  //       }),
  //     },
  //   );
  //   const result = await res.json();
  //   if (res.ok) {
  //     waMessageId = result?.messages?.[0]?.id ?? null;
  //     status = "sent";
  //   } else {
  //     status = "failed";
  //     console.error("[razorpay-webhook] Meta send failed", res.status, result);
  //   }
  //
  // NOTE: a payment confirmation is business-initiated, so it will almost
  // always fall OUTSIDE Meta's 24h customer-service window and must go out as
  // an APPROVED TEMPLATE, not free-form text. Register a payment_confirmation
  // template and pass its name via `templateName`.
  if (!phone) {
    console.warn(
      "[razorpay-webhook] no phone on file for this member — logging the " +
        "message but there is nobody to deliver it to.",
    );
  }
  console.log(
    `[razorpay-webhook] SIMULATED SEND -> to=${phone ?? "(unknown)"} text=${
      JSON.stringify(text)
    }`,
  );
  // ----------------- END SIMULATED SEND — REPLACE THIS BLOCK -----------------

  // The whatsapp_messages row is real either way — it is our outbound audit log.
  const { error } = await supabase.from("whatsapp_messages").insert({
    organization_id: context.organizationId ?? null,
    member_id: context.memberId ?? null,
    direction: "outbound",
    template_name: context.templateName ?? null,
    body_preview: text,
    wa_message_id: waMessageId,
    status,
    related_payment_id: context.relatedPaymentId ?? null,
  });

  if (error) {
    // Never let logging failure break reconciliation — the money already moved.
    console.error("[razorpay-webhook] failed to log outbound message:", error);
  }
}

// ---------------------------------------------------------------------------
// Payment lookup
// ---------------------------------------------------------------------------

/**
 * Match Razorpay's entity to one of our `payments` rows.
 *
 * FOUR TIERS, most exact first. Every tier is an equality match on a value we
 * ourselves put into Razorpay — none of them guess.
 *
 * ===========================================================================
 * WHY TIERS 3 AND 4 EXIST — the payment.failed gap
 * ===========================================================================
 * Tiers 1 and 2 leave a real hole, and it is not hypothetical:
 *
 *   - `payment.failed` carries ONLY payload.payment.entity. There is no
 *     payment_link block on that event, so razorpayLinkId is null unless the
 *     payment entity happens to carry payment_link_id (Razorpay does not
 *     guarantee it).
 *   - The matching payments row was created by send-renewal-reminder with
 *     provider_payment_id deliberately NULL — it is only backfilled when a
 *     payment SUCCEEDS. A payment that never succeeded has nothing to backfill
 *     from, so tier 1 cannot match either.
 *
 * Result before this change: a member's failed renewal payment logged
 * "NO MATCHING PAYMENTS ROW", the payments row stayed 'pending' forever, and
 * nobody was told the payment had failed. The same hole is reachable for
 * payment.captured whenever the captured event arrives without a link block.
 *
 * ===========================================================================
 * WHY THESE FALLBACKS ARE SAFE — and why the originally-proposed one was not
 * ===========================================================================
 * The fallback first sketched for this was "organization_id + membership_id +
 * status='pending'", derived from nothing — which is unimplementable, because a
 * bare payment payload contains neither of those columns. Deriving them by
 * guessing ("the newest pending payment") could mark an unrelated member's
 * payment as failed, which is worse than not matching at all.
 *
 * The identifiers therefore come from Razorpay `notes`, which
 * send-renewal-reminder attaches to every payment link it creates:
 *     notes: { organization_id, membership_id, idempotency_key }
 * Razorpay echoes a link's notes onto the payment made from it and into every
 * webhook for that payment, so for anything that originated here the ids are
 * present in the payload — as data we wrote, not as an inference.
 *
 *   Tier 3  payments.idempotency_key — a UNIQUE column. An exact match on a
 *           primary-key-strength identifier: it is either the right row or no
 *           row. This is the tier that will fire in practice, because
 *           send-renewal-reminder always writes all three notes.
 *
 *   Tier 4  organization_id + membership_id + status='pending', newest first.
 *           Both ids come from our own notes, so this CANNOT cross a tenant or
 *           member boundary — the worst case is picking the wrong *period's*
 *           pending payment for the right member, and only if that member has
 *           two pending rows at once and the notes carried membership_id but
 *           not idempotency_key. send-renewal-reminder never produces that
 *           combination; this tier is a net for links created by other tooling
 *           (a dashboard link with notes added by hand, a future function).
 *
 * A payment with no notes at all — a Razorpay dashboard link, a Payment Pages
 * collection, a direct API charge — is genuinely un-attributable and still
 * falls through to the "NO MATCHING PAYMENTS ROW" error log. That log is the
 * correct outcome for those, not a bug to paper over.
 *
 * These tiers only ever ADD matches; no payload that matched before can stop
 * matching, which is why this change cannot regress the existing suite.
 */
async function findPaymentRow(
  supabase: SupabaseClient,
  extracted: ExtractedPayment,
): Promise<{ row: PaymentRow; matchedBy: MatchedBy } | null> {
  // --- Tier 1: provider_payment_id (UNIQUE, exact) ---
  if (extracted.razorpayPaymentId) {
    const { data, error } = await supabase
      .from("payments")
      .select(PAYMENT_SELECT)
      .eq("provider_payment_id", extracted.razorpayPaymentId)
      .limit(1)
      .maybeSingle();

    if (error) throw error;
    if (data) return { row: data as PaymentRow, matchedBy: "provider_payment_id" };
  }

  // --- Tier 2: razorpay_link_id ---
  if (extracted.razorpayLinkId) {
    // razorpay_link_id is NOT unique in the schema, so take the newest.
    const { data, error } = await supabase
      .from("payments")
      .select(PAYMENT_SELECT)
      .eq("razorpay_link_id", extracted.razorpayLinkId)
      .order("created_at", { ascending: false })
      .limit(1)
      .maybeSingle();

    if (error) throw error;
    if (data) return { row: data as PaymentRow, matchedBy: "razorpay_link_id" };
  }

  // --- Tier 3: notes.idempotency_key (UNIQUE, exact) ---
  if (extracted.notes.idempotencyKey) {
    const { data, error } = await supabase
      .from("payments")
      .select(PAYMENT_SELECT)
      .eq("idempotency_key", extracted.notes.idempotencyKey)
      .limit(1)
      .maybeSingle();

    if (error) throw error;
    if (data) {
      console.log(
        "[razorpay-webhook] matched via notes.idempotency_key " +
          `${extracted.notes.idempotencyKey} — the payload carried no usable ` +
          "payment or link id.",
      );
      return { row: data as PaymentRow, matchedBy: "notes_idempotency_key" };
    }
  }

  // --- Tier 4: notes.organization_id + notes.membership_id, still pending ---
  // Both ids REQUIRED together: membership_id alone would be a tenant-wide
  // lookup, and this function must never widen past the tenant we were told.
  if (extracted.notes.membershipId && extracted.notes.organizationId) {
    const { data, error } = await supabase
      .from("payments")
      .select(PAYMENT_SELECT)
      .eq("organization_id", extracted.notes.organizationId)
      .eq("membership_id", extracted.notes.membershipId)
      .eq("status", "pending")
      .order("created_at", { ascending: false })
      .limit(1)
      .maybeSingle();

    if (error) throw error;
    if (data) {
      console.warn(
        "[razorpay-webhook] matched via notes.membership_id " +
          `${extracted.notes.membershipId} (newest pending payment for that ` +
          "membership). Less precise than idempotency_key — check that link's " +
          "notes if this recurs.",
      );
      return { row: data as PaymentRow, matchedBy: "notes_membership_id" };
    }
  }

  return null;
}

/** Loud warning when Razorpay's amount disagrees with what we billed. */
function warnOnAmountMismatch(row: PaymentRow, extracted: ExtractedPayment): void {
  if (extracted.amount === null) return;

  const expected = Number(row.amount);
  if (Math.abs(expected - extracted.amount) < 0.005) return;

  console.error(
    `[razorpay-webhook] AMOUNT MISMATCH on payment ${row.id}: ` +
      `we billed ₹${expected}, Razorpay captured ₹${extracted.amount}. ` +
      "Reconciling anyway — investigate manually.",
  );
}

// ---------------------------------------------------------------------------
// Event handlers
// ---------------------------------------------------------------------------

async function handlePaymentSuccess(
  supabase: SupabaseClient,
  event: string,
  extracted: ExtractedPayment,
): Promise<Record<string, unknown>> {
  const found = await findPaymentRow(supabase, extracted);

  if (!found) {
    // Shouldn't happen if send-renewal-reminder always creates the row first.
    // Ack anyway: retries won't conjure the row, and a 5xx loop would bury
    // real failures. This log is the signal to reconcile by hand.
    console.error(
      `[razorpay-webhook] NO MATCHING PAYMENTS ROW. event=${event} ` +
        `razorpay_payment_id=${extracted.razorpayPaymentId} ` +
        `razorpay_link_id=${extracted.razorpayLinkId} amount=₹${extracted.amount} ` +
        `notes=${JSON.stringify(extracted.notes)}. ` +
        "Money was captured at Razorpay with nothing to reconcile against.",
    );
    return { skipped: "payment_not_found" };
  }

  const { row, matchedBy } = found;

  // Defence in depth alongside the webhook_events guard: a payment already
  // marked success must never be extended twice.
  if (row.status === "success") {
    console.log(
      `[razorpay-webhook] payment ${row.id} is already 'success' — no-op.`,
    );
    return { skipped: "already_success", matched_by: matchedBy };
  }

  warnOnAmountMismatch(row, extracted);

  const paymentUpdate: Record<string, unknown> = {
    status: "success",
    reconciled_at: new Date().toISOString(),
  };
  // Backfills provider_payment_id on rows that were matched by link id.
  if (extracted.razorpayPaymentId) {
    paymentUpdate.provider_payment_id = extracted.razorpayPaymentId;
  }

  const { error: paymentError } = await supabase
    .from("payments")
    .update(paymentUpdate)
    .eq("id", row.id);

  if (paymentError) {
    // provider_payment_id is UNIQUE — a clash means this Razorpay payment is
    // already recorded against a DIFFERENT row. Don't guess; surface it.
    if (paymentError.code === "23505") {
      console.error(
        `[razorpay-webhook] provider_payment_id ${extracted.razorpayPaymentId} ` +
          `is already attached to another payments row; refusing to reassign ` +
          `it to ${row.id}. Reconcile manually.`,
      );
      return { skipped: "provider_payment_id_conflict" };
    }
    throw paymentError;
  }

  // --- Extend the membership period ---
  const membership = row.memberships;
  let newPeriodEnd: string | null = null;

  if (!membership) {
    // memberships.membership_id is NOT NULL, so this is defensive only.
    console.error(
      `[razorpay-webhook] payment ${row.id} has no readable membership ` +
        `(membership_id=${row.membership_id}); payment marked success but no ` +
        "period was extended.",
    );
  } else {
    // Extend from whichever is later, so paying early adds a month rather than
    // truncating the remaining period.
    const extendFrom = laterDate(
      todayInBillingTimezone(),
      membership.current_period_end,
    );
    newPeriodEnd = addOneMonth(extendFrom);

    const { error: membershipError } = await supabase
      .from("memberships")
      .update({ status: "active", current_period_end: newPeriodEnd })
      .eq("id", membership.id);

    if (membershipError) throw membershipError;

    console.log(
      `[razorpay-webhook] membership ${membership.id} extended ` +
        `${membership.current_period_end} -> ${newPeriodEnd} (from ${extendFrom})`,
    );
  }

  await sendWhatsAppMessage(
    supabase,
    membership?.members?.phone ?? null,
    MESSAGE.paymentReceived(
      newPeriodEnd ? formatDateForMember(newPeriodEnd) : "your next billing date",
    ),
    {
      memberId: membership?.member_id ?? null,
      organizationId: row.organization_id,
      relatedPaymentId: row.id,
      // TODO(meta): set to the approved payment_confirmation template name.
      templateName: null,
    },
  );

  return {
    handled: "payment_success",
    matched_by: matchedBy,
    payment_id: row.id,
    new_period_end: newPeriodEnd,
  };
}

async function handlePaymentFailure(
  supabase: SupabaseClient,
  event: string,
  extracted: ExtractedPayment,
): Promise<Record<string, unknown>> {
  const found = await findPaymentRow(supabase, extracted);

  if (!found) {
    console.error(
      `[razorpay-webhook] NO MATCHING PAYMENTS ROW for failure. event=${event} ` +
        `razorpay_payment_id=${extracted.razorpayPaymentId} ` +
        `razorpay_link_id=${extracted.razorpayLinkId} ` +
        `notes=${JSON.stringify(extracted.notes)}. ` +
        "If notes are empty this payment did not originate from " +
        "send-renewal-reminder and is genuinely un-attributable.",
    );
    return { skipped: "payment_not_found" };
  }

  const { row, matchedBy } = found;

  // A late failure callback must not clobber a payment that already succeeded.
  if (row.status === "success") {
    console.warn(
      `[razorpay-webhook] ignoring '${event}' for payment ${row.id}: already ` +
        "reconciled as success. Not downgrading.",
    );
    return { skipped: "already_success", matched_by: matchedBy };
  }

  const { error } = await supabase
    .from("payments")
    .update({ status: "failed" })
    .eq("id", row.id);

  if (error) throw error;

  // NOTE: membership status is deliberately untouched. A failed attempt on a
  // still-active membership must not revoke access — deciding when to move a
  // membership to past_due/expired is a dunning policy, and belongs in the
  // scheduled reminder job, not in a payment callback.

  const membership = row.memberships;

  await sendWhatsAppMessage(
    supabase,
    membership?.members?.phone ?? null,
    MESSAGE.paymentFailed,
    {
      memberId: membership?.member_id ?? null,
      organizationId: row.organization_id,
      relatedPaymentId: row.id,
      templateName: null,
    },
  );

  return { handled: "payment_failed", matched_by: matchedBy, payment_id: row.id };
}

// ---------------------------------------------------------------------------
// Request handling
// ---------------------------------------------------------------------------

async function handleWebhook(req: Request): Promise<Response> {
  // Raw body first — the signature is computed over these exact bytes.
  const rawBody = await req.text();

  const verdict = await verifyRazorpaySignature(req, rawBody);

  if (verdict === "misconfigured") {
    return json({ error: "webhook_secret_not_configured" }, 500);
  }

  if (verdict === "invalid") {
    // 400 and nothing else: an unverified payload is not a real event, so it
    // must not reach webhook_events or any business logic.
    console.warn("[razorpay-webhook] rejected: invalid X-Razorpay-Signature");
    return json({ error: "invalid_signature" }, 400);
  }

  let body: any;
  try {
    body = JSON.parse(rawBody);
  } catch (err) {
    console.error("[razorpay-webhook] signature valid but body unparseable:", err);
    return json({ ok: true, ignored: "unparseable_body" });
  }

  const supabase = createAdminClient();
  const event: string = typeof body?.event === "string" ? body.event : "unknown";
  const { eventId, derivedFrom } = resolveEventId(req, body);

  // --- Idempotency guard: claim the event BEFORE any business logic. ---
  const { data: eventRow, error: eventError } = await supabase
    .from("webhook_events")
    .insert({ source: SOURCE, event_id: eventId, payload: body })
    .select("id")
    .single();

  if (eventError) {
    // 23505 = unique_violation on webhook_events (source, event_id).
    if (eventError.code === "23505") {
      console.log(`[razorpay-webhook] duplicate event ${eventId} — skipping.`);
      return json({ ok: true, duplicate: true });
    }
    console.error("[razorpay-webhook] webhook_events insert failed:", eventError);
    return json({ ok: true, error: "event_insert_failed" });
  }

  console.log(
    `[razorpay-webhook] event=${event} id=${eventId} (via ${derivedFrom})`,
  );

  try {
    const extracted = extractPayment(body);
    let result: Record<string, unknown>;

    if (SUCCESS_EVENTS.includes(event)) {
      result = await handlePaymentSuccess(supabase, event, extracted);
    } else if (FAILURE_EVENTS.includes(event)) {
      result = await handlePaymentFailure(supabase, event, extracted);
    } else {
      // Forward-compatible: record it, do nothing, don't error.
      console.log(`[razorpay-webhook] no handler for event '${event}' — ignoring.`);
      result = { handled: "ignored" };
    }

    // Mark processed for successes AND gracefully-skipped edge cases.
    const { error: processedError } = await supabase
      .from("webhook_events")
      .update({ processed: true })
      .eq("id", eventRow.id);

    if (processedError) {
      console.error("[razorpay-webhook] failed to mark processed:", processedError);
    }

    return json({ ok: true, event, ...result });
  } catch (err) {
    // Leave processed = false so the row is a durable record of the failure and
    // can be replayed by a backfill job. Still 200: Razorpay retrying won't fix
    // a logic bug, and the payload is safely stored either way.
    console.error(`[razorpay-webhook] processing failed for ${eventId}:`, err);
    return json({ ok: true, event, error: "processing_failed" });
  }
}

// ---------------------------------------------------------------------------
// Entrypoint
// ---------------------------------------------------------------------------

Deno.serve(async (req: Request) => {
  // Razorpay only ever POSTs. There is no GET handshake (unlike Meta) — you
  // paste the URL into Dashboard → Settings → Webhooks and it validates by
  // delivering a test event.
  if (req.method !== "POST") {
    return json({ error: "method_not_allowed" }, 405);
  }

  return await handleWebhook(req);
});
