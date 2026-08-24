// whatsapp-webhook — Meta WhatsApp Cloud API webhook receiver.
//
// GET  → Meta's webhook verification handshake (hub.challenge echo).
// POST → inbound WhatsApp messages: resolve tenant, parse intent, act, reply.
//
// ============================================================================
// OUTBOUND SENDING — real Meta Cloud API, free-form text
// ============================================================================
// sendWhatsAppMessage() below calls the real Meta Cloud API. Every reply here
// is a free-form "type":"text" message sent in direct response to an inbound
// message, so it is always within Meta's 24h customer-service window and does
// NOT need an approved template (unlike renewal_reminder / daily_owner_brief,
// which are business-initiated — see ../_shared/whatsapp.ts).
//
// WHATSAPP_SEND_MODE=mock skips the real call (console.log + 'queued' row
// instead) — see the SEND MODE note at the top of ../_shared/whatsapp.ts for
// why that is an opt-in for test runs rather than a runtime default.
//
// Every remaining temporary/stubbed piece is tagged with `TODO(meta)`,
// `TODO(razorpay)` or `TODO(convo)` so it is easy to grep for:
//   rg 'TODO\((meta|razorpay|convo)\)' supabase/functions
// ============================================================================

// Setup type definitions for built-in Supabase Runtime APIs (Deno.env, etc).
import "@supabase/functions-js/edge-runtime.d.ts";
import { createAdminClient, type SupabaseClient } from "../_shared/supabase.ts";
import { hmacSha256Hex, timingSafeEqualHex } from "../_shared/crypto.ts";
import { expectedServiceRoleKey } from "../_shared/auth.ts";

// NOTE: we intentionally do NOT use `withSupabase({ auth: [...] })` from
// @supabase/server here. That wrapper requires a Supabase apiKey on every
// request, and Meta's webhook servers will never send one — they authenticate
// via the verify-token handshake (GET) and an X-Hub-Signature-256 HMAC (POST).
// `verify_jwt = false` is already set for this function in supabase/config.toml.

const SOURCE = "meta" as const;

// ---------------------------------------------------------------------------
// Reply copy — kept in one place so it is easy to swap for Meta message
// templates later (approved templates are required for business-initiated
// messages; free-form text is only allowed inside a 24h customer service window).
// TODO(meta): map these to approved template names + fill whatsapp_messages.template_name.
// ---------------------------------------------------------------------------
const REPLY = {
  checkedIn: "Checked in ✅",
  membershipCancelled:
    "Your membership is cancelled. Reply PAY to start a new one, or talk to your gym's front desk.",
  noMembership:
    "We couldn't find a membership on file for you — please check with your gym's front desk.",
  notFound: "We couldn't find you — check with your gym's front desk",
  unknown:
    "Sorry, I didn't understand. Reply IN to check in, or PAY to renew your membership.",
  // --- Real payment-link outcomes, from requestPaymentLink() below ---
  paymentLinkSentToday:
    "We already sent you a payment link earlier today — check your recent " +
    "WhatsApp messages, or ask the front desk if you can't find it.",
  paymentAlreadyPaid:
    "You're already paid up for this period — no payment needed right now. See you at the gym!",
  paymentOptedOut:
    "You've opted out of WhatsApp payment messages — please contact the front desk to renew.",
  paymentError:
    "Sorry, we couldn't generate your payment link right now — please contact the front desk to renew.",
} as const;

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

type Intent = "checkin" | "switch" | "pay" | "unknown";

interface InboundMessage {
  /** Meta's wamid.* message id — our idempotency key. */
  id: string | null;
  /** Sender phone as Meta sends it (digits, no '+'). */
  from: string | null;
  /** Best-effort text body of the message. */
  body: string;
}

interface GymOption {
  memberId: string;
  organizationId: string;
  gymName: string;
}

type Resolution =
  | { kind: "resolved"; memberId: string; organizationId: string }
  | { kind: "not_found" }
  | { kind: "ambiguous"; options: GymOption[] };

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
 * Normalize an inbound phone number to the shape we store in `members.phone`
 * and `member_active_context.phone`: digits only, no '+', no separators.
 *
 * TODO: decide the canonical stored format and enforce it at write time too
 * (front-desk UI, CSV import). Right now a member saved as "+91 99999 99999"
 * would not match Meta's "919999999999" — this helper only fixes the inbound
 * side. A 10-digit local Indian number is deliberately NOT auto-prefixed with
 * 91 here, because silently rewriting numbers hides data-entry bugs.
 */
function normalizePhone(raw: string): string {
  return raw.replace(/\D/g, "");
}

/**
 * Pull the first actual message out of Meta's deeply-nested webhook envelope.
 * Shape: entry[].changes[].value.messages[]
 */
function extractFirstMessage(payload: any): InboundMessage | null {
  const entries = Array.isArray(payload?.entry) ? payload.entry : [];

  for (const entry of entries) {
    const changes = Array.isArray(entry?.changes) ? entry.changes : [];
    for (const change of changes) {
      const messages = change?.value?.messages;
      if (!Array.isArray(messages) || messages.length === 0) continue;

      const message = messages[0];
      return {
        id: typeof message?.id === "string" ? message.id : null,
        from: typeof message?.from === "string" ? message.from : null,
        body: extractBody(message),
      };
    }
  }

  return null;
}

/**
 * Text of the message. Meta puts the payload in a different place depending on
 * message type; we handle the ones the check-in / switch flows can produce.
 * TODO(convo): handle location, image and template-reply message types.
 */
function extractBody(message: any): string {
  return (
    message?.text?.body ??
      message?.button?.text ??
      message?.interactive?.button_reply?.title ??
      message?.interactive?.list_reply?.title ??
      ""
  );
}

function parseIntent(body: string): Intent {
  const text = body.trim().toLowerCase().replace(/\s+/g, " ");

  if (text === "in" || text === "checkin" || text === "check in") return "checkin";
  if (text === "switch") return "switch";
  if (text === "pay") return "pay";

  // TODO(convo): a bare "1" / "2" reply to a gym-disambiguation prompt lands in
  // `unknown` for now. Wiring it up needs conversation state (e.g. a
  // pending_prompt column on member_active_context, or a short-lived KV row)
  // so we know which numbered list the reply refers to.
  return "unknown";
}

function formatGymList(options: GymOption[], lead: string): string {
  const lines = options.map((o, i) => `${i + 1} for ${o.gymName}`);
  return `${lead} Reply ${lines.join(", ")}`;
}

// ===========================================================================
// OUTBOUND MESSAGING — real Meta Cloud API
// ===========================================================================

const META_API_VERSION = "v21.0";

function isMockMode(): boolean {
  return (Deno.env.get("WHATSAPP_SEND_MODE") ?? "").trim().toLowerCase() === "mock";
}

/**
 * Call the real Meta Cloud API. Never throws — a bad token or a Meta outage
 * must not crash the webhook; Meta only needs its 200.
 */
async function callMetaApi(
  phone: string,
  text: string,
): Promise<{ waMessageId: string | null; status: "sent" | "failed" }> {
  const accessToken = Deno.env.get("META_ACCESS_TOKEN");
  const phoneNumberId = Deno.env.get("META_PHONE_NUMBER_ID");

  if (!accessToken || !phoneNumberId) {
    console.error(
      "[whatsapp-webhook] CRITICAL: META_ACCESS_TOKEN / META_PHONE_NUMBER_ID not set — cannot send.",
    );
    return { waMessageId: null, status: "failed" };
  }

  try {
    const res = await fetch(
      `https://graph.facebook.com/${META_API_VERSION}/${phoneNumberId}/messages`,
      {
        method: "POST",
        headers: {
          authorization: `Bearer ${accessToken}`,
          "content-type": "application/json",
        },
        body: JSON.stringify({
          messaging_product: "whatsapp",
          recipient_type: "individual",
          to: phone,
          type: "text",
          text: { preview_url: false, body: text },
        }),
      },
    );

    const result = await res.json().catch(() => null);

    if (res.ok) {
      const waMessageId = result?.messages?.[0]?.id ?? null;
      return { waMessageId, status: "sent" };
    }

    console.error(`[whatsapp-webhook] Meta send failed (HTTP ${res.status}):`, result);
    return { waMessageId: null, status: "failed" };
  } catch (err) {
    console.error(
      "[whatsapp-webhook] Meta send threw:",
      err instanceof Error ? err.message : err,
    );
    return { waMessageId: null, status: "failed" };
  }
}

/**
 * Send a WhatsApp message to `phone` and record it in whatsapp_messages.
 *
 * Every reply sent from here is a free-form reply to an inbound message, so it
 * is always within the 24h customer-service window — no template needed.
 * WHATSAPP_SEND_MODE=mock skips the real call; see ../_shared/whatsapp.ts.
 */
async function sendWhatsAppMessage(
  supabase: SupabaseClient,
  phone: string,
  text: string,
  context: {
    memberId?: string | null;
    organizationId?: string | null;
    templateName?: string | null;
  } = {},
): Promise<void> {
  let waMessageId: string | null = null;
  let status: "queued" | "sent" | "failed";

  if (isMockMode()) {
    console.log(
      `[whatsapp-webhook] WHATSAPP_SEND_MODE=mock — not calling Meta. to=${phone} text=${
        JSON.stringify(text)
      }`,
    );
    status = "queued";
  } else {
    const outcome = await callMetaApi(phone, text);
    waMessageId = outcome.waMessageId;
    status = outcome.status;
  }

  // The whatsapp_messages row is real either way — it is our outbound audit log.
  const { error } = await supabase.from("whatsapp_messages").insert({
    organization_id: context.organizationId ?? null,
    member_id: context.memberId ?? null,
    direction: "outbound",
    template_name: context.templateName ?? null,
    body_preview: text,
    wa_message_id: waMessageId,
    status,
  });

  if (error) {
    // Never let logging failure break the webhook — Meta only needs its 200.
    console.error("[whatsapp-webhook] failed to log outbound message:", error);
  }
}

// ===========================================================================
// PAYMENT LINKS — real, via an internal call to send-renewal-reminder
// ===========================================================================
// A member texting PAY (or checking IN with a past_due/expired membership)
// needs a real Razorpay payment link. Rather than duplicate link creation,
// idempotency and guard logic here, this calls send-renewal-reminder the same
// way renewal-scan does — service-role-to-service-role, one membership at a
// time. That function already sends the WhatsApp message itself (with the
// real link) on success, so requestPaymentLink() returns `null` in that case:
// "already handled, nothing more to say." It only returns text for outcomes
// that need a DIFFERENT reply than a silent success — a skip, or a failure.

/** http://kong:8000 locally, https://<project-ref>.supabase.co when deployed. */
function reminderUrl(): string | null {
  const override = Deno.env.get("SEND_RENEWAL_REMINDER_URL");
  if (override) return override;

  const base = Deno.env.get("SUPABASE_URL");
  return base
    ? `${base.replace(/\/+$/, "")}/functions/v1/send-renewal-reminder`
    : null;
}

/** The member's current-period membership — same "latest by period end" pick as handleCheckin. */
async function loadLatestMembership(
  supabase: SupabaseClient,
  organizationId: string,
  memberId: string,
): Promise<{ id: string } | null> {
  const { data, error } = await supabase
    .from("memberships")
    .select("id")
    .eq("organization_id", organizationId)
    .eq("member_id", memberId)
    .order("current_period_end", { ascending: false })
    .limit(1)
    .maybeSingle();

  if (error) throw error;

  return data;
}

/**
 * Ask send-renewal-reminder for a real payment link on `membershipId`.
 *
 * Returns `null` when send-renewal-reminder already sent the WhatsApp message
 * itself (created or reused a link) — the caller must NOT send anything else.
 * Returns reply text for every other outcome (skip or failure), since those
 * leave the member with no message otherwise.
 *
 * NEVER THROWS — mirrors renewal-scan's sendOne(): a network hiccup or a
 * malformed response here must fall back to REPLY.paymentError, not crash the
 * webhook.
 */
async function requestPaymentLink(membershipId: string): Promise<string | null> {
  const url = reminderUrl();
  const serviceKey = expectedServiceRoleKey();

  if (!url || !serviceKey) {
    console.error(
      "[whatsapp-webhook] CRITICAL: cannot reach send-renewal-reminder — " +
        `${!url ? "SUPABASE_URL" : "SUPABASE_SERVICE_ROLE_KEY"} not set.`,
    );
    return REPLY.paymentError;
  }

  let res: Response;
  try {
    res = await fetch(url, {
      method: "POST",
      headers: {
        authorization: `Bearer ${serviceKey}`,
        "content-type": "application/json",
      },
      body: JSON.stringify({ membership_id: membershipId }),
    });
  } catch (err) {
    console.error(
      "[whatsapp-webhook] send-renewal-reminder call threw:",
      err instanceof Error ? err.message : err,
    );
    return REPLY.paymentError;
  }

  const body = await res.json().catch(() => null);

  if (body === null || !res.ok || body.ok !== true) {
    console.error(
      `[whatsapp-webhook] send-renewal-reminder returned an error (HTTP ${res.status}):`,
      body,
    );
    return REPLY.paymentError;
  }

  switch (body.skipped) {
    case "already_sent_today":
      return REPLY.paymentLinkSentToday;
    case "already_paid":
      return REPLY.paymentAlreadyPaid;
    case "whatsapp_opt_out":
      return REPLY.paymentOptedOut;
  }

  if (body.created === true || body.reused === true) {
    // send-renewal-reminder already sent the WhatsApp message with the link.
    return null;
  }

  console.error(
    "[whatsapp-webhook] send-renewal-reminder returned an unrecognised shape:",
    body,
  );
  return REPLY.paymentError;
}

/** Record the inbound message for audit / support history. */
async function logInboundMessage(
  supabase: SupabaseClient,
  message: InboundMessage,
  context: { memberId?: string | null; organizationId?: string | null },
): Promise<void> {
  const { error } = await supabase.from("whatsapp_messages").insert({
    organization_id: context.organizationId ?? null,
    member_id: context.memberId ?? null,
    direction: "inbound",
    body_preview: message.body,
    wa_message_id: message.id,
    // Meta only delivers a webhook once it has the message, so 'delivered' is
    // the accurate inbound state.
    status: "delivered",
  });

  if (error) {
    console.error("[whatsapp-webhook] failed to log inbound message:", error);
  }
}

// ---------------------------------------------------------------------------
// Tenant resolution — which gym is this phone number "at" right now?
// ---------------------------------------------------------------------------

/** All (member, org) pairs this phone maps to, with gym names for prompts. */
async function findMembersForPhone(
  supabase: SupabaseClient,
  phone: string,
): Promise<GymOption[]> {
  const { data, error } = await supabase
    .from("members")
    .select("id, organization_id, organizations(name)")
    .eq("phone", phone);

  if (error) throw error;

  return (data ?? []).map((row: any) => ({
    memberId: row.id,
    organizationId: row.organization_id,
    gymName: row.organizations?.name ?? "your gym",
  }));
}

async function resolvePhone(
  supabase: SupabaseClient,
  phone: string,
): Promise<Resolution> {
  // 1. Fast path: an explicit active context wins.
  const { data: activeContext, error: contextError } = await supabase
    .from("member_active_context")
    .select("active_member_id, active_org_id")
    .eq("phone", phone)
    .maybeSingle();

  if (contextError) throw contextError;

  if (activeContext) {
    return {
      kind: "resolved",
      memberId: activeContext.active_member_id,
      organizationId: activeContext.active_org_id,
    };
  }

  // 2. No context yet — look the phone up across all orgs.
  const options = await findMembersForPhone(supabase, phone);

  if (options.length === 0) return { kind: "not_found" };

  if (options.length === 1) {
    const only = options[0];

    // Belongs to exactly one gym: pin the context so later messages skip the lookup.
    const { error } = await supabase.from("member_active_context").upsert({
      phone,
      active_member_id: only.memberId,
      active_org_id: only.organizationId,
      updated_at: new Date().toISOString(),
    }, { onConflict: "phone" });

    if (error) throw error;

    return {
      kind: "resolved",
      memberId: only.memberId,
      organizationId: only.organizationId,
    };
  }

  // 3. Same phone at 2+ gyms and no active context — must ask.
  return { kind: "ambiguous", options };
}

// ---------------------------------------------------------------------------
// Intent handlers — each returns the reply text to send back.
// ---------------------------------------------------------------------------

async function handleCheckin(
  supabase: SupabaseClient,
  memberId: string,
  organizationId: string,
): Promise<string | null> {
  // Most recent membership for this member, by period end.
  const { data: membership, error } = await supabase
    .from("memberships")
    .select("id, status, current_period_end")
    .eq("organization_id", organizationId)
    .eq("member_id", memberId)
    .order("current_period_end", { ascending: false })
    .limit(1)
    .maybeSingle();

  if (error) throw error;

  if (!membership) return REPLY.noMembership;

  if (membership.status === "past_due" || membership.status === "expired") {
    // No attendance row: an unpaid member must not be able to self-check-in.
    // Real payment link, sent by send-renewal-reminder itself on success —
    // see requestPaymentLink() above.
    return await requestPaymentLink(membership.id);
  }

  if (membership.status === "cancelled") return REPLY.membershipCancelled;

  // status === 'active'
  // TODO: consider de-duplicating repeat check-ins within the same day
  // (a partial unique index on (member_id, date(checked_in_at)) or a lookback query).
  const { error: attendanceError } = await supabase.from("attendance").insert({
    organization_id: organizationId,
    member_id: memberId,
    source: "whatsapp_self",
    marked_by: null, // self-service, no staff user involved
  });

  if (attendanceError) throw attendanceError;

  return REPLY.checkedIn;
}

async function handleSwitch(
  supabase: SupabaseClient,
  phone: string,
): Promise<string> {
  const options = await findMembersForPhone(supabase, phone);

  if (options.length === 0) return REPLY.notFound;
  if (options.length === 1) {
    return `You're only registered at ${options[0].gymName}, so there's nothing to switch to.`;
  }

  // TODO(convo): this only *shows* the list. The full flow — remember that we
  // asked, accept a "1"/"2" reply, then update member_active_context — needs
  // conversation state; see the note in parseIntent().
  return formatGymList(options, "You're registered at multiple gyms.");
}

// ---------------------------------------------------------------------------
// POST authentication — X-Hub-Signature-256
//
// Meta signs every webhook POST with HMAC-SHA256 over the RAW request body,
// keyed on the app secret, and sends it as `X-Hub-Signature-256: sha256=<hex>`.
// Without this check anyone who can reach the URL can forge an inbound message
// and cause a check-in, because `verify_jwt = false` for this function.
//
// Behaviour is deliberately gated on META_APP_SECRET being present:
//   set     → enforce; a missing/invalid signature is rejected with 403.
//   unset   → skip with a loud warning, so unsigned local curl still works.
// Set META_APP_SECRET in supabase/functions/.env (and as a project secret in
// production) to turn enforcement on. Going live is an env change, not a code
// change.
// ---------------------------------------------------------------------------

const SIGNATURE_HEADER = "x-hub-signature-256";
const SIGNATURE_PREFIX = "sha256=";

type SignatureVerdict = "ok" | "invalid" | "skipped";

/**
 * `rawBody` MUST be the exact bytes Meta sent — see the note on hmacSha256Hex
 * in ../_shared/crypto.ts for why handleWebhook reads text() and parses
 * manually rather than calling req.json().
 */
async function verifyMetaSignature(
  req: Request,
  rawBody: string,
): Promise<SignatureVerdict> {
  const secret = Deno.env.get("META_APP_SECRET");

  if (!secret) {
    console.warn(
      "[whatsapp-webhook] META_APP_SECRET is not set — SKIPPING signature " +
        "verification. Acceptable locally; never in production.",
    );
    return "skipped";
  }

  const header = req.headers.get(SIGNATURE_HEADER);
  if (!header || !header.startsWith(SIGNATURE_PREFIX)) return "invalid";

  const provided = header.slice(SIGNATURE_PREFIX.length).toLowerCase();
  const expected = await hmacSha256Hex(secret, rawBody);

  return timingSafeEqualHex(provided, expected) ? "ok" : "invalid";
}

// ---------------------------------------------------------------------------
// GET — Meta webhook verification handshake
// ---------------------------------------------------------------------------

function handleVerification(url: URL): Response {
  const mode = url.searchParams.get("hub.mode");
  const token = url.searchParams.get("hub.verify_token");
  const challenge = url.searchParams.get("hub.challenge");

  const expected = Deno.env.get("META_VERIFY_TOKEN");

  if (!expected) {
    console.error("[whatsapp-webhook] META_VERIFY_TOKEN is not set — rejecting.");
    return new Response("Forbidden", { status: 403 });
  }

  if (token !== expected) {
    console.warn(`[whatsapp-webhook] verification failed (hub.mode=${mode})`);
    return new Response("Forbidden", { status: 403 });
  }

  console.log(`[whatsapp-webhook] verification ok (hub.mode=${mode})`);

  // Meta requires the raw challenge string echoed back as plain text.
  return new Response(challenge ?? "", {
    status: 200,
    headers: { "content-type": "text/plain" },
  });
}

// ---------------------------------------------------------------------------
// POST — inbound messages
// ---------------------------------------------------------------------------

async function handleWebhook(req: Request): Promise<Response> {
  // Read the raw body FIRST — the signature is computed over these exact bytes.
  const rawBody = await req.text();

  // Authenticate before doing anything else. This is the one POST failure mode
  // that does NOT return 200: a bad signature means the caller is not Meta, so
  // there is no retry worth encouraging and forged traffic should be rejected
  // loudly rather than silently acked.
  const verdict = await verifyMetaSignature(req, rawBody);
  if (verdict === "invalid") {
    console.warn("[whatsapp-webhook] rejected POST: invalid X-Hub-Signature-256");
    return json({ error: "invalid_signature" }, 403);
  }

  let payload: any;
  try {
    payload = JSON.parse(rawBody);
  } catch (err) {
    console.error("[whatsapp-webhook] unparseable body:", err);
    return json({ ok: true, ignored: "unparseable_body" });
  }

  const supabase = createAdminClient();
  const message = extractFirstMessage(payload);

  // Not a message event — most often a delivery/read status callback, which
  // Meta sends under `value.statuses`. Ack so Meta stops retrying.
  // TODO(meta): consume `value.statuses` to advance whatsapp_messages.status
  // (sent → delivered → read) by wa_message_id.
  if (!message || !message.from) {
    console.log("[whatsapp-webhook] no inbound message in payload — acking.");
    return json({ ok: true, ignored: "no_message" });
  }

  // --- (a) Idempotency guard: claim the event BEFORE any business logic. ---
  // Meta retries webhooks aggressively; without this, a retry would double
  // check-in the member.
  const eventId = message.id ?? `generated-${crypto.randomUUID()}`;

  const { data: event, error: eventError } = await supabase
    .from("webhook_events")
    .insert({ source: SOURCE, event_id: eventId, payload })
    .select("id")
    .single();

  if (eventError) {
    // 23505 = unique_violation on webhook_events (source, event_id).
    if (eventError.code === "23505") {
      console.log(`[whatsapp-webhook] duplicate event ${eventId} — skipping.`);
      return json({ ok: true, duplicate: true });
    }
    // Anything else means we cannot guarantee exactly-once. Fail closed on the
    // business logic but still 200 so Meta does not hammer us.
    console.error("[whatsapp-webhook] webhook_events insert failed:", eventError);
    return json({ ok: true, error: "event_insert_failed" });
  }

  try {
    // --- (b) Normalize the sender phone. ---
    const phone = normalizePhone(message.from);

    // --- (c) Resolve the tenant. ---
    const resolution = await resolvePhone(supabase, phone);

    const memberId = resolution.kind === "resolved" ? resolution.memberId : null;
    const organizationId = resolution.kind === "resolved"
      ? resolution.organizationId
      : null;

    // --- (f) Log the inbound message. ---
    // Done before the reply so the whatsapp_messages log reads chronologically.
    await logInboundMessage(supabase, message, { memberId, organizationId });

    // --- (d) Decide the reply. `null` means "already sent elsewhere" (see
    // --- requestPaymentLink()) — no further send happens at step (e).
    let reply: string | null;

    if (resolution.kind === "not_found") {
      reply = REPLY.notFound;
    } else if (resolution.kind === "ambiguous") {
      // No attendance, no context write — we don't know which gym they mean.
      reply = formatGymList(
        resolution.options,
        "You're registered at multiple gyms.",
      );
    } else {
      const intent = parseIntent(message.body);
      console.log(
        `[whatsapp-webhook] phone=${phone} org=${resolution.organizationId} intent=${intent}`,
      );

      switch (intent) {
        case "checkin":
          reply = await handleCheckin(
            supabase,
            resolution.memberId,
            resolution.organizationId,
          );
          break;
        case "switch":
          reply = await handleSwitch(supabase, phone);
          break;
        case "pay": {
          const membership = await loadLatestMembership(
            supabase,
            resolution.organizationId,
            resolution.memberId,
          );
          reply = membership
            ? await requestPaymentLink(membership.id)
            : REPLY.noMembership;
          break;
        }
        default:
          reply = REPLY.unknown;
      }
    }

    // --- (e) "Send" the reply, unless requestPaymentLink() already sent one. ---
    if (reply !== null) {
      await sendWhatsAppMessage(supabase, phone, reply, {
        memberId,
        organizationId,
      });
    }

    // --- (g) Mark the event processed. ---
    const { error: processedError } = await supabase
      .from("webhook_events")
      .update({ processed: true })
      .eq("id", event.id);

    if (processedError) {
      console.error("[whatsapp-webhook] failed to mark processed:", processedError);
    }

    // --- (h) Always 200. ---
    return json({ ok: true, event_id: eventId, resolution: resolution.kind });
  } catch (err) {
    // Leave webhook_events.processed = false so the row is a durable record of
    // the failure and can be replayed by a backfill job.
    console.error(`[whatsapp-webhook] processing failed for ${eventId}:`, err);
    return json({ ok: true, error: "processing_failed" });
  }
}

// ---------------------------------------------------------------------------
// Entrypoint
// ---------------------------------------------------------------------------

Deno.serve(async (req: Request) => {
  const url = new URL(req.url);

  if (req.method === "GET") return handleVerification(url);
  if (req.method === "POST") return await handleWebhook(req);

  return json({ error: "method_not_allowed" }, 405);
});

/* ---------------------------------------------------------------------------
 * Local testing — see the curl commands in the chat / README.
 * Remember: (source, event_id) is UNIQUE, so bump the `wamid.*` value on every
 * run or the second call will correctly short-circuit as a duplicate.
 * ------------------------------------------------------------------------- */
