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
import { orgStatusIsActive } from "../_shared/org-status.ts";

// NOTE: we intentionally do NOT use `withSupabase({ auth: [...] })` from
// @supabase/server here. That wrapper requires a Supabase apiKey on every
// request, and Meta's webhook servers will never send one — they authenticate
// via the verify-token handshake (GET) and an X-Hub-Signature-256 HMAC (POST).
// `verify_jwt = false` is already set for this function in supabase/config.toml.

const SOURCE = "meta" as const;

// Fixed-offset billing zone (Asia/Kolkata, no DST) — matches BILLING_TIMEZONE
// in razorpay-webhook / renewal-scan / daily-owner-brief. Used only by the
// owner-command handlers for "today" / month boundaries.
const BILLING_TZ = Deno.env.get("BILLING_TIMEZONE") ?? "Asia/Kolkata";

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
  orgInactive:
    "This gym's account is currently inactive. Please contact the gym directly — " +
    "check-ins and messages are paused until it's restored.",
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

  if (membership.status === "frozen") {
    // No attendance row, no payment link — a frozen member owes nothing and
    // simply isn't due back yet. Look up the governing freeze for
    // frozen_until: the most recent membership_freezes row for this
    // membership is unambiguous while status='frozen' — see
    // 20260904090000_membership_freezing.sql's header for why.
    const { data: freeze, error: freezeError } = await supabase
      .from("membership_freezes")
      .select("frozen_until")
      .eq("membership_id", membership.id)
      .order("created_at", { ascending: false })
      .limit(1)
      .maybeSingle();
    if (freezeError) throw freezeError;

    return freeze
      ? `Your membership is currently paused until ${fmtDay(freeze.frozen_until)}. ` +
          `Reply again after that to check in, or contact the front desk to resume early.`
      // Unreachable in practice (status='frozen' implies a freeze row exists),
      // but a clean generic reply beats a crash if the two ever disagree.
      : "Your membership is currently paused. Contact the front desk for details.";
  }

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

// ===========================================================================
// OWNER / COACH COMMANDS — a parallel, read-only intent path
// ===========================================================================
// If the inbound phone is an organization's owner_phone (not a member), it is
// routed here instead of the member flow; a users row with role='coach' and a
// matching phone gets the single coach command. All replies are free-form text
// inside the 24h service window — no templates — and every read is scoped to
// the ONE org resolved from the phone. NOTHING here writes business data or is
// callable from a cron.
//
// PHONE RESOLUTION PRIORITY (see resolveSender):  owner  >  coach  >  member.
//   owner  = organizations.owner_phone = phone  OR  a users row with
//            role='owner' AND phone = phone  (co-owners: a gym can have 2+).
//   coach  = a users row with role='coach' AND phone = phone.
//   member = the existing member_active_context / members path, unchanged.
// Each check is an exact phone equality; owner is deduped by org id so a
// person who is both owner_phone and an owner-role user for one gym resolves
// once. A person who owns 2+ gyms (by either mechanism) is owner_ambiguous.
// front_desk staff who are not an owner or coach fall through to the member
// path unchanged.
// ===========================================================================

type SenderRole =
  | { kind: "owner"; organizationId: string; orgName: string }
  | { kind: "owner_ambiguous"; orgs: { id: string; name: string }[] }
  | { kind: "coach"; userId: string; organizationId: string; name: string }
  | { kind: "coach_ambiguous"; names: string[] }
  | { kind: "org_suspended"; organizationId: string | null }
  | { kind: "member" };

type OwnerCommand =
  | "revenue" | "alerts" | "today" | "overdue" | "pt"
  | "coaches" | "lapsed" | "new" | "help";

async function resolveSender(
  supabase: SupabaseClient,
  phone: string,
): Promise<SenderRole> {
  // OWNER — a gym can have multiple co-owners, so this matches BOTH ways:
  //   (a) organizations.owner_phone = phone   (the signup / billing contact,
  //       and the fallback for an org that has no owner-role users yet)
  //   (b) a users row with role='owner' AND phone = phone
  // The union of org ids from both is the set this phone owns. Deduping by
  // org id means a person who is BOTH owner_phone AND a users role='owner'
  // row for the same gym still resolves to one org, and a single-owner org
  // relying only on owner_phone behaves exactly as before.
  const [byOwnerPhone, ownerUsers] = await Promise.all([
    supabase.from("organizations").select("id, name").eq("owner_phone", phone),
    supabase.from("users").select("organization_id").eq("role", "owner").eq("phone", phone),
  ]);
  if (byOwnerPhone.error) throw byOwnerPhone.error;
  if (ownerUsers.error) throw ownerUsers.error;

  const ownedOrgIds = new Set<string>();
  for (const o of byOwnerPhone.data ?? []) ownedOrgIds.add(o.id);
  for (const u of ownerUsers.data ?? []) ownedOrgIds.add(u.organization_id);

  if (ownedOrgIds.size >= 1) {
    const ids = [...ownedOrgIds];
    const { data: ownedOrgs, error: ownedErr } = await supabase
      .from("organizations").select("id, name, status").in("id", ids);
    if (ownedErr) throw ownedErr;
    // Suspended orgs drop out entirely — an owner of a suspended gym gets no
    // owner commands. An owner of 2 gyms, one suspended, sees only the live one.
    const list = (ownedOrgs ?? [])
      .filter((o: any) => orgStatusIsActive(o.status))
      .map((o: any) => ({ id: o.id, name: o.name }));
    if (list.length === 0) {
      return { kind: "org_suspended", organizationId: (ownedOrgs ?? [])[0]?.id ?? null };
    }
    if (list.length === 1) {
      return { kind: "owner", organizationId: list[0].id, orgName: list[0].name };
    }
    // Owner of 2+ gyms (via either mechanism) — same "can't disambiguate over
    // WhatsApp" limitation the member `ambiguous` path has.
    return { kind: "owner_ambiguous", orgs: list };
  }

  const { data: coaches, error: coachErr } = await supabase
    .from("users")
    .select("id, name, organization_id, organizations(status)")
    .eq("role", "coach")
    .eq("phone", phone);
  if (coachErr) throw coachErr;
  const liveCoaches = (coaches ?? []).filter((c: any) =>
    orgStatusIsActive(c.organizations?.status)
  );
  if (liveCoaches.length === 1) {
    return {
      kind: "coach",
      userId: liveCoaches[0].id,
      organizationId: liveCoaches[0].organization_id,
      name: liveCoaches[0].name,
    };
  }
  if (liveCoaches.length > 1) {
    return { kind: "coach_ambiguous", names: liveCoaches.map((c: any) => c.name) };
  }
  // Every coach row for this phone was at a suspended org — not a member.
  if ((coaches ?? []).length > 0) {
    return { kind: "org_suspended", organizationId: (coaches ?? [])[0]?.organization_id ?? null };
  }

  return { kind: "member" };
}

// --- command parsing ------------------------------------------------------

function normalizeCommand(body: string): string {
  return body.trim().toLowerCase().replace(/\s+/g, "");
}

function parseOwnerCommand(body: string): OwnerCommand {
  const map: Record<string, OwnerCommand> = {
    revenue: "revenue", rev: "revenue",
    alerts: "alerts", alert: "alerts",
    today: "today",
    overdue: "overdue", due: "overdue",
    pt: "pt",
    coaches: "coaches", coach: "coaches",
    lapsed: "lapsed",
    new: "new",
    help: "help", menu: "help", commands: "help", hi: "help",
  };
  return map[normalizeCommand(body)] ?? "help";
}

/**
 * Coach path commands. MYCLIENTS lists active clients; SESSION / LOG generate a
 * one-time magic link into the quick-log page (see coachStartSession). Anything
 * else is coach help.
 */
function parseCoachCommand(body: string): "myclients" | "session" | "help" {
  const t = normalizeCommand(body);
  if (t === "myclients" || t === "clients") return "myclients";
  if (t === "session" || t === "log") return "session";
  return "help";
}

/**
 * base64url (RFC 4648 §5, no padding) of raw bytes. 32 bytes -> 43 chars,
 * matching validate-magic-link's TOKEN_RE and the coach_magic_links.token
 * column. Local so whatsapp-webhook has no new shared-module dependency.
 */
function base64Url(bytes: Uint8Array): string {
  let bin = "";
  for (const b of bytes) bin += String.fromCharCode(b);
  return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

/**
 * Where the coach quick-log page lives. The SESSION magic link points a coach
 * here with ?token=…. Set COACH_QUICK_LOG_BASE_URL in production
 * (e.g. https://app.example.com); the default is the local Vite dev server.
 */
function coachQuickLogUrl(token: string): string {
  const base = (Deno.env.get("COACH_QUICK_LOG_BASE_URL") ?? "http://localhost:5173")
    .replace(/\/+$/, "");
  return `${base}/coach/quick-log?token=${token}`;
}

// --- formatting helpers -------------------------------------------------

function rupees(n: number): string {
  return "₹" + Math.round(Number(n) || 0).toLocaleString("en-IN");
}

/** Today's date (YYYY-MM-DD) in the billing zone. */
function todayDateStr(): string {
  return new Intl.DateTimeFormat("en-CA", {
    timeZone: BILLING_TZ,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).format(new Date());
}

/** UTC instant of 00:00 today in the billing zone (fixed +05:30, no DST). */
function startOfTodayIso(): string {
  const OFFSET = 5.5 * 3600 * 1000;
  const istMidnight = Math.floor((Date.now() + OFFSET) / 86400000) * 86400000 - OFFSET;
  return new Date(istMidnight).toISOString();
}

/** First day (YYYY-MM-DD) of the month `offset` months from the current one. */
function monthStartStr(offset: number): string {
  const [y, m] = todayDateStr().split("-").map(Number);
  return new Date(Date.UTC(y, m - 1 + offset, 1)).toISOString().slice(0, 10);
}

/** Whole days between a past YYYY-MM-DD and today (billing zone). */
function daysSince(dateStr: string): number {
  const [y, m, d] = dateStr.slice(0, 10).split("-").map(Number);
  const [ty, tm, td] = todayDateStr().split("-").map(Number);
  return Math.round((Date.UTC(ty, tm - 1, td) - Date.UTC(y, m - 1, d)) / 86400000);
}

/** Add months to YYYY-MM-DD, clamping to month end — same rule as razorpay-webhook. */
function addMonthsStr(dateStr: string, months: number): string {
  const [y, m, d] = dateStr.slice(0, 10).split("-").map(Number);
  const total = y * 12 + (m - 1) + months;
  const ty = Math.floor(total / 12);
  const tm = (total % 12) + 1;
  const lastDay = new Date(Date.UTC(ty, tm, 0)).getUTCDate();
  const cd = Math.min(d, lastDay);
  return `${String(ty).padStart(4, "0")}-${String(tm).padStart(2, "0")}-${String(cd).padStart(2, "0")}`;
}

function fmtDay(dateStr: string | null): string {
  if (!dateStr) return "never";
  const [y, m, d] = dateStr.slice(0, 10).split("-").map(Number);
  // en-GB → "5 Sep" (en-IN renders "5 Sept").
  return new Intl.DateTimeFormat("en-GB", { day: "numeric", month: "short", timeZone: "UTC" })
    .format(new Date(Date.UTC(y, m - 1, d)));
}

function goalLabel(g: string): string {
  return ({ muscle_gain: "Muscle gain", fat_loss: "Fat loss", general_fitness: "General fitness" } as Record<string, string>)[g] ?? g;
}

/**
 * Render at most `cap` items, then a "+N more" line. Keeps OVERDUE / LAPSED /
 * NEW from producing a message long enough to be truncated by WhatsApp.
 */
function capList<T>(items: T[], cap: number, render: (t: T, i: number) => string): string {
  const shown = items.slice(0, cap).map((t, i) => render(t, i));
  const more = items.length - cap;
  return shown.join("\n") + (more > 0 ? `\n+${more} more` : "");
}

const LIST_CAP = 10;

// --- the "attention" predicate, recomputed from pt_packages ---------------
// v_pt_packages_attention's own WHERE is bound to auth.jwt(); a keyless
// service_role caller always gets zero rows from it. This is the identical
// rule, scoped to `org`.
interface AttentionPkg {
  memberName: string;
  coachName: string;
  goal: string;
  remaining: number;
  daysUntilEnd: number;
  endDate: string;
  low: boolean;
  expiring: boolean;
}

async function loadAttention(
  supabase: SupabaseClient,
  org: string,
): Promise<AttentionPkg[]> {
  const { data, error } = await supabase
    .from("pt_packages")
    .select("sessions_purchased, sessions_used, start_date, duration_months, goal, members(name), coach:users(name)")
    .eq("organization_id", org)
    .eq("status", "active");
  if (error) throw error;

  const out: AttentionPkg[] = [];
  for (const p of (data ?? []) as any[]) {
    const remaining = Number(p.sessions_purchased) - Number(p.sessions_used);
    const endDate = addMonthsStr(p.start_date, Number(p.duration_months));
    const daysUntilEnd = -daysSince(endDate);
    const low = remaining <= 2;
    const expiring = daysUntilEnd <= 7;
    if (low || expiring) {
      out.push({
        memberName: p.members?.name ?? "Member",
        coachName: p.coach?.name ?? "coach",
        goal: p.goal,
        remaining,
        daysUntilEnd,
        endDate,
        low,
        expiring,
      });
    }
  }
  return out;
}

// --- owner command handlers ---------------------------------------------

async function ownerRevenue(supabase: SupabaseClient, org: string, orgName: string): Promise<string> {
  const from = monthStartStr(-1);
  const { data, error } = await supabase
    .from("v_daily_revenue_by_source")
    .select("day, source, total")
    .eq("organization_id", org)
    .gte("day", from);
  if (error) throw error;

  const thisStart = monthStartStr(0);
  let thisMem = 0, thisPt = 0, lastTotal = 0;
  for (const r of (data ?? []) as any[]) {
    const day = String(r.day).slice(0, 10);
    const amt = Number(r.total) || 0;
    if (day >= thisStart) {
      if (r.source === "pt_package") thisPt += amt; else thisMem += amt;
    } else {
      lastTotal += amt;
    }
  }
  const monthName = new Intl.DateTimeFormat("en-IN", { month: "long", timeZone: "UTC" })
    .format(new Date(thisStart + "T00:00:00Z"));

  return [
    `💰 Revenue — ${orgName} (${monthName})`,
    `Total: ${rupees(thisMem + thisPt)}`,
    `  • Memberships: ${rupees(thisMem)}`,
    `  • PT packages: ${rupees(thisPt)}`,
    `Last month: ${rupees(lastTotal)}`,
  ].join("\n");
}

async function ownerOverdueRows(supabase: SupabaseClient, org: string) {
  const { data, error } = await supabase
    .from("memberships")
    .select("current_period_end, total_price, members(name)")
    .eq("organization_id", org)
    .eq("status", "past_due")
    .order("current_period_end", { ascending: true });
  if (error) throw error;
  return ((data ?? []) as any[]).map((m) => ({
    name: m.members?.name ?? "Member",
    amount: Number(m.total_price) || 0,
    daysLate: daysSince(m.current_period_end),
  }));
}

async function ownerAlerts(supabase: SupabaseClient, org: string, orgName: string): Promise<string> {
  const overdue = await ownerOverdueRows(supabase, org);
  const owed = overdue.reduce((s, r) => s + r.amount, 0);
  const attn = await loadAttention(supabase, org);
  const low = attn.filter((a) => a.low).length;
  const expiring = attn.filter((a) => a.expiring).length;

  return [
    `⚠️ Alerts — ${orgName}`,
    `Overdue: ${overdue.length} member${overdue.length === 1 ? "" : "s"} · ${rupees(owed)} owed`,
    `PT attention: ${attn.length} package${attn.length === 1 ? "" : "s"} (${low} low on sessions, ${expiring} expiring soon)`,
    ``,
    `Text OVERDUE or PT for the full list.`,
  ].join("\n");
}

async function ownerToday(supabase: SupabaseClient, org: string, orgName: string): Promise<string> {
  const today = todayDateStr();
  const dayStart = startOfTodayIso();
  const since24h = new Date(Date.now() - 24 * 3600 * 1000).toISOString();

  const [checkins, renewals, sessions, failed] = await Promise.all([
    supabase.from("attendance").select("id", { count: "exact", head: true })
      .eq("organization_id", org).gte("checked_in_at", dayStart),
    supabase.from("memberships").select("id", { count: "exact", head: true })
      .eq("organization_id", org).in("status", ["active", "past_due"]).eq("current_period_end", today),
    supabase.from("training_notes").select("id", { count: "exact", head: true })
      .eq("organization_id", org).eq("session_date", today),
    supabase.from("whatsapp_messages").select("id", { count: "exact", head: true })
      .eq("organization_id", org).eq("direction", "outbound").eq("status", "failed").gte("created_at", since24h),
  ]);
  for (const r of [checkins, renewals, sessions, failed]) if (r.error) throw r.error;

  return [
    `📅 Today — ${orgName}`,
    `Check-ins: ${checkins.count ?? 0}`,
    `Renewals due today: ${renewals.count ?? 0}`,
    `PT sessions logged: ${sessions.count ?? 0}`,
    `Failed sends (24h): ${failed.count ?? 0}`,
  ].join("\n");
}

async function ownerOverdue(supabase: SupabaseClient, org: string, orgName: string): Promise<string> {
  const rows = await ownerOverdueRows(supabase, org);
  if (rows.length === 0) return `🔴 Overdue — ${orgName}\nNo past-due memberships. 🎉`;
  return [
    `🔴 Overdue — ${orgName} (${rows.length} total)`,
    capList(rows, LIST_CAP, (r, i) => `${i + 1}. ${r.name} — ${rupees(r.amount)} · ${r.daysLate}d late`),
  ].join("\n");
}

async function ownerPt(supabase: SupabaseClient, org: string, orgName: string): Promise<string> {
  const [pkgCount, ptMembers, rev, attn] = await Promise.all([
    supabase.from("pt_packages").select("id", { count: "exact", head: true })
      .eq("organization_id", org).eq("status", "active"),
    supabase.from("v_members_pt_status").select("id", { count: "exact", head: true })
      .eq("organization_id", org).eq("has_active_pt", true),
    supabase.from("v_daily_revenue_by_source").select("total")
      .eq("organization_id", org).eq("source", "pt_package").gte("day", monthStartStr(0)),
    loadAttention(supabase, org),
  ]);
  for (const r of [pkgCount, ptMembers, rev] as any[]) if (r.error) throw r.error;

  const ptRevenue = ((rev.data ?? []) as any[]).reduce((s, r) => s + (Number(r.total) || 0), 0);
  const low = attn.filter((a) => a.low);
  const expiring = attn.filter((a) => a.expiring && !a.low);

  const lines = [
    `🏋️ PT — ${orgName}`,
    `Active packages: ${pkgCount.count ?? 0} · ${ptMembers.count ?? 0} member${(ptMembers.count ?? 0) === 1 ? "" : "s"}`,
    `PT revenue this month: ${rupees(ptRevenue)}`,
  ];
  if (low.length) {
    lines.push("", `Low on sessions (${low.length}):`);
    lines.push(capList(low, LIST_CAP, (a) => ` • ${a.memberName} — ${a.remaining} left (${a.coachName})`));
  }
  if (expiring.length) {
    lines.push("", `Expiring soon (${expiring.length}):`);
    lines.push(capList(expiring, LIST_CAP, (a) => ` • ${a.memberName} — ends ${fmtDay(a.endDate)} (${a.coachName})`));
  }
  if (!low.length && !expiring.length) lines.push("", "No packages need attention right now.");
  return lines.join("\n");
}

async function ownerCoaches(supabase: SupabaseClient, org: string, orgName: string): Promise<string> {
  const recentSince = new Date(Date.now() - 7 * 86400000).toISOString(); // same 7-day window as OwnerDashboard
  const [coachRes, activeRes, recentRes, lastRes] = await Promise.all([
    supabase.from("users").select("id, name").eq("organization_id", org).eq("role", "coach"),
    supabase.from("pt_packages").select("coach_id").eq("organization_id", org).eq("status", "active"),
    supabase.from("training_notes").select("coach_id").eq("organization_id", org).gte("created_at", recentSince),
    supabase.from("training_notes").select("coach_id, session_date").eq("organization_id", org),
  ]);
  for (const r of [coachRes, activeRes, recentRes, lastRes]) if (r.error) throw r.error;

  const activeCount = new Map<string, number>();
  for (const r of (activeRes.data ?? []) as any[]) activeCount.set(r.coach_id, (activeCount.get(r.coach_id) ?? 0) + 1);
  const loggedRecently = new Set(((recentRes.data ?? []) as any[]).map((r) => r.coach_id));
  const lastSession = new Map<string, string>();
  for (const r of (lastRes.data ?? []) as any[]) {
    const cur = lastSession.get(r.coach_id);
    if (!cur || r.session_date > cur) lastSession.set(r.coach_id, r.session_date);
  }

  const coaches = (coachRes.data ?? []) as any[];
  if (coaches.length === 0) return `🧑‍🏫 Coaches — ${orgName}\nNo coaches on the team yet.`;

  const lines = coaches.map((c) => {
    const clients = activeCount.get(c.id) ?? 0;
    const last = lastSession.get(c.id) ?? null;
    const ago = last ? `last ${daysSince(last)}d ago` : "no sessions yet";
    const status = loggedRecently.has(c.id) ? "logging ✅" : "quiet ⚠️";
    return `${c.name} — ${clients} client${clients === 1 ? "" : "s"} · ${status} (${ago})`;
  });
  return [`🧑‍🏫 Coaches — ${orgName}`, ...lines].join("\n");
}

async function ownerLapsed(supabase: SupabaseClient, org: string, orgName: string): Promise<string> {
  const { data, error } = await supabase
    .from("v_lapsed_members")
    .select("name, last_visit")
    .eq("organization_id", org)
    .order("last_visit", { ascending: true, nullsFirst: true });
  if (error) throw error;
  const rows = (data ?? []) as any[];
  if (rows.length === 0) return `😴 Lapsed — ${orgName}\nEveryone has checked in within the last 14 days. 💪`;
  return [
    `😴 Lapsed — ${orgName}`,
    `${rows.length} member${rows.length === 1 ? "" : "s"} haven't checked in for 14+ days.`,
    ``,
    capList(rows, LIST_CAP, (r, i) =>
      `${i + 1}. ${r.name} — ${r.last_visit ? "last seen " + fmtDay(r.last_visit) : "never checked in"}`),
  ].join("\n");
}

async function ownerNew(supabase: SupabaseClient, org: string, orgName: string): Promise<string> {
  const thisStart = monthStartStr(0);
  const lastStart = monthStartStr(-1);
  const [thisRes, lastRes] = await Promise.all([
    supabase.from("members")
      .select("id, name, memberships(membership_plans(name)), pt_packages(id)")
      .eq("organization_id", org).gte("created_at", thisStart).order("created_at", { ascending: true }),
    supabase.from("members").select("id", { count: "exact", head: true })
      .eq("organization_id", org).gte("created_at", lastStart).lt("created_at", thisStart),
  ]);
  if (thisRes.error) throw thisRes.error;
  if (lastRes.error) throw lastRes.error;

  const rows = (thisRes.data ?? []) as any[];
  const lines = [
    `✨ New members — ${orgName}`,
    `This month: ${rows.length}  (last month: ${lastRes.count ?? 0})`,
  ];
  if (rows.length) {
    lines.push("");
    lines.push(capList(rows, LIST_CAP, (r, i) => {
      const plan = r.memberships?.[0]?.membership_plans?.name ?? null;
      const hasPt = (r.pt_packages?.length ?? 0) > 0;
      const tag = [plan, hasPt ? "PT" : null].filter(Boolean).join(" + ") || "no plan yet";
      return `${i + 1}. ${r.name} — ${tag}`;
    }));
  }
  return lines.join("\n");
}

function ownerHelp(orgName: string): string {
  return [
    `🤖 Commands — ${orgName}`,
    `REVENUE  — this month's total + membership/PT split, vs last month`,
    `ALERTS   — overdue + PT-attention summary`,
    `TODAY    — check-ins, renewals due, PT sessions, failed sends (24h)`,
    `OVERDUE  — every past-due member: name, amount, days late`,
    `PT       — active packages, PT revenue, low/expiring list`,
    `COACHES  — each coach's client count + logging activity`,
    `LAPSED   — members with no check-in for 14+ days`,
    `NEW      — members who joined this month`,
    `SESSION  — coach command: a link to log a training session (alias: LOG)`,
    `HELP     — this list`,
  ].join("\n");
}

async function handleOwnerCommand(
  supabase: SupabaseClient,
  cmd: OwnerCommand,
  org: string,
  orgName: string,
): Promise<string> {
  switch (cmd) {
    case "revenue": return await ownerRevenue(supabase, org, orgName);
    case "alerts": return await ownerAlerts(supabase, org, orgName);
    case "today": return await ownerToday(supabase, org, orgName);
    case "overdue": return await ownerOverdue(supabase, org, orgName);
    case "pt": return await ownerPt(supabase, org, orgName);
    case "coaches": return await ownerCoaches(supabase, org, orgName);
    case "lapsed": return await ownerLapsed(supabase, org, orgName);
    case "new": return await ownerNew(supabase, org, orgName);
    default: return ownerHelp(orgName);
  }
}

// --- coach command -----------------------------------------------------

async function coachMyClients(
  supabase: SupabaseClient,
  coachUserId: string,
  coachOrg: string,
  coachName: string,
): Promise<string> {
  // Scoped to THIS coach's id — never another coach's clients. The
  // organization_id filter is defence in depth; coach_id alone is sufficient.
  const { data, error } = await supabase
    .from("pt_packages")
    .select("goal, sessions_used, sessions_purchased, members(name)")
    .eq("organization_id", coachOrg)
    .eq("coach_id", coachUserId)
    .eq("status", "active")
    .order("start_date", { ascending: true });
  if (error) throw error;

  const rows = (data ?? []) as any[];
  if (rows.length === 0) return `🏋️ ${coachName} — you have no active clients right now.`;
  return [
    `🏋️ Your clients (${rows.length}) — ${coachName}`,
    capList(rows, 20, (r, i) =>
      `${i + 1}. ${r.members?.name ?? "Member"} — ${goalLabel(r.goal)} · ${r.sessions_used}/${r.sessions_purchased} sessions`),
  ].join("\n");
}

/**
 * SESSION / LOG — mint a single-use, 15-minute magic link into the coach
 * quick-log page and reply with it.
 *
 * The link is an auth-bypass mechanism (validate-magic-link redeems the token
 * for a real coach session with no PIN), so:
 *   * the token is 256 bits of CSPRNG output — unguessable;
 *   * the coach_magic_links row is written BEFORE the reply goes out, so
 *     generation is always audited even if the Meta send then fails;
 *   * expiry is short and single-use is enforced at redemption (see
 *     validate-magic-link + the migration header).
 * This function only GENERATES; it never establishes a session itself.
 */
async function coachStartSession(
  supabase: SupabaseClient,
  coachUserId: string,
  coachOrg: string,
  coachName: string,
): Promise<string> {
  const raw = new Uint8Array(32);
  crypto.getRandomValues(raw);
  const token = base64Url(raw);
  const expiresAt = new Date(Date.now() + 15 * 60 * 1000).toISOString();

  const { data: row, error } = await supabase
    .from("coach_magic_links")
    .insert({
      coach_user_id: coachUserId,
      organization_id: coachOrg,
      token,
      expires_at: expiresAt,
    })
    .select("id")
    .single();
  if (error) throw error;

  // Generation audit line — pairs with validate-magic-link's redemption line
  // (same link id) for the full trail on this auth-bypass path.
  console.log(
    `[whatsapp-webhook] magic-link generated id=${row.id} coach=${coachUserId} ` +
      `org=${coachOrg} expires=${expiresAt}`,
  );

  return [
    `🏋️ ${coachName} — tap to log a session:`,
    coachQuickLogUrl(token),
    ``,
    `Valid for 15 minutes, one use. It signs you in on this device — don't forward it.`,
  ].join("\n");
}

function coachHelp(coachName: string): string {
  return `🏋️ ${coachName} — reply MYCLIENTS for your active client list (name, goal, sessions used/purchased), or SESSION (alias: LOG) for a link to log a training session. Owner reports (REVENUE, ALERTS, etc.) are owner-only.`;
}

// --- dispatcher: owns the whole request for an owner/coach sender -------

async function handleStaffCommand(
  supabase: SupabaseClient,
  sender: Exclude<SenderRole, { kind: "member" }>,
  message: InboundMessage,
  phone: string,
  eventRowId: string,
  eventId: string,
): Promise<Response> {
  let reply: string;
  let orgForLog: string | null = null;

  if (sender.kind === "owner") {
    orgForLog = sender.organizationId;
    const cmd = parseOwnerCommand(message.body);
    console.log(`[whatsapp-webhook] owner phone=${phone} org=${sender.organizationId} cmd=${cmd}`);
    reply = await handleOwnerCommand(supabase, cmd, sender.organizationId, sender.orgName);
  } else if (sender.kind === "coach") {
    orgForLog = sender.organizationId;
    const cmd = parseCoachCommand(message.body);
    console.log(`[whatsapp-webhook] coach phone=${phone} org=${sender.organizationId} cmd=${cmd}`);
    reply = cmd === "myclients"
      ? await coachMyClients(supabase, sender.userId, sender.organizationId, sender.name)
      : cmd === "session"
      ? await coachStartSession(supabase, sender.userId, sender.organizationId, sender.name)
      : coachHelp(sender.name);
  } else if (sender.kind === "org_suspended") {
    // Every gym this phone is an owner/coach at is suspended. No commands, no
    // magic links — just say why, same copy as the member path.
    orgForLog = sender.organizationId;
    console.log(`[whatsapp-webhook] staff phone=${phone} org=${sender.organizationId} — suspended, no commands.`);
    reply = REPLY.orgInactive;
  } else if (sender.kind === "owner_ambiguous") {
    // No owner_active_context table and no conversation state (see the
    // TODO(convo) notes) — the same "can only show the list" limitation the
    // member `ambiguous` path has. Flagged, not silently guessed.
    const names = sender.orgs.map((o) => o.name).join(", ");
    reply =
      `This number is the registered owner contact for more than one gym (${names}). ` +
      `WhatsApp commands can't tell them apart yet — please use the owner dashboard, ` +
      `or contact support to split the numbers.`;
  } else {
    const names = sender.names.join(", ");
    reply =
      `This number is registered as a coach at more than one gym (${names}). ` +
      `WhatsApp commands can't tell them apart yet — please use the coach app.`;
  }

  await logInboundMessage(supabase, message, { memberId: null, organizationId: orgForLog });
  await sendWhatsAppMessage(supabase, phone, reply, { memberId: null, organizationId: orgForLog });

  const { error: processedError } = await supabase
    .from("webhook_events").update({ processed: true }).eq("id", eventRowId);
  if (processedError) console.error("[whatsapp-webhook] failed to mark processed:", processedError);

  return json({ ok: true, event_id: eventId, resolution: sender.kind });
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

    // --- (b2) Owner / coach command path. Checked BEFORE member resolution:
    // --- an owner_phone / coach phone is never in the member flow. Returns
    // --- the full 200 response itself (logs inbound, sends reply, marks the
    // --- event processed). The member path below is untouched for everyone
    // --- else (in / pay / switch).
    const sender = await resolveSender(supabase, phone);
    if (sender.kind !== "member") {
      return await handleStaffCommand(supabase, sender, message, phone, event.id, eventId);
    }

    // --- (c) Resolve the tenant. ---
    const resolution = await resolvePhone(supabase, phone);

    const memberId = resolution.kind === "resolved" ? resolution.memberId : null;
    const organizationId = resolution.kind === "resolved"
      ? resolution.organizationId
      : null;

    // --- (c2) Suspended tenant: a resolved member at a suspended org gets a
    // --- clean "account inactive" reply and NO check-in — same freeze as the
    // --- owner/coach path. Checked here so the log below still records the
    // --- inbound message against the right org.
    let orgSuspended = false;
    if (resolution.kind === "resolved") {
      const { data: orgRow, error: orgRowErr } = await supabase
        .from("organizations").select("status").eq("id", organizationId!).maybeSingle();
      if (orgRowErr) throw orgRowErr;
      orgSuspended = !orgStatusIsActive((orgRow as any)?.status);
    }

    // --- (f) Log the inbound message. ---
    // Done before the reply so the whatsapp_messages log reads chronologically.
    await logInboundMessage(supabase, message, { memberId, organizationId });

    // --- (d) Decide the reply. `null` means "already sent elsewhere" (see
    // --- requestPaymentLink()) — no further send happens at step (e).
    let reply: string | null;

    if (orgSuspended) {
      console.log(`[whatsapp-webhook] phone=${phone} org=${organizationId} — suspended, no check-in.`);
      reply = REPLY.orgInactive;
    } else if (resolution.kind === "not_found") {
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
