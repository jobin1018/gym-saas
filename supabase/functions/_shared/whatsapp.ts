// Shared outbound WhatsApp helper — real Meta WhatsApp Cloud API sends.
//
// ============================================================================
// SEND MODE
// ============================================================================
// Real Meta credentials (META_ACCESS_TOKEN / META_PHONE_NUMBER_ID) are wired in
// and verified end-to-end. sendWhatsAppMessage() below calls the real Cloud API
// UNLESS WHATSAPP_SEND_MODE=mock is set, in which case it falls back to the old
// console.log + 'queued' behaviour and makes no network call.
//
// Default (WHATSAPP_SEND_MODE unset or anything other than "mock") is LIVE —
// this is a deliberate choice: the whole point of this change is that sends are
// real now, so "real" has to be what happens when nobody has configured
// anything. The safety net for automated tests lives in each test.sh's
// preflight instead (mirroring the existing `rzp_live_` guard in
// send-renewal-reminder/test.sh): every suite that would trigger a send refuses
// to run unless WHATSAPP_SEND_MODE=mock is set in the serving environment. See
// the note in each test.sh for why a code-level default couldn't do this job on
// its own — supabase functions serve reads one .env for both manual real-send
// testing and automated test runs, so only an explicit, checked opt-in for the
// test suites (not a runtime default) can guarantee they never hit the real API.
//
// The whatsapp_messages row is REAL either way — it is the outbound audit log,
// and send-renewal-reminder additionally uses it as its once-per-day guard.
//
// ============================================================================
// TEMPLATES vs FREE-FORM TEXT
// ============================================================================
// Pass a 5th `template` argument to send an APPROVED message template (required
// for any business-initiated message outside the 24h customer-service window —
// confirmed in production: Meta rejects free-form sends outside that window
// with "more than 24 hours have passed since the customer last replied").
// Approved and in use: payment_confirmation, daily_owner_brief, renewal_reminder
// (all language "en_GB" — Meta's code for "English (UK)", not plain "en").
// Omit `template` to send free-form text instead — still a REAL call, just not
// template-wrapped. That is deliberately still used for razorpay-webhook's
// payment.failed notice, which has no approved template yet (see the TODO(meta)
// at that call site). `text` is always what gets written to whatsapp_messages'
// body_preview, whether or not a template was actually used to send — it is the
// human-readable audit trail, not required to be byte-identical to Meta's own
// template rendering.
//
// NOTE ON DUPLICATION: whatsapp-webhook/index.ts carries its own copy of this
// helper with the same WHATSAPP_SEND_MODE handling (they predate this file and
// both are working, so they were deliberately left untouched as separate
// copies) — its replies (check-in confirmation, "didn't understand",
// disambiguation) stay free-form on purpose: they are genuine replies inside an
// open service window and Meta does not require a template for those.
// razorpay-webhook/index.ts now imports this file directly (its old private,
// fully-simulated copy and BEGIN/END SIMULATED SEND fence are gone).
// ============================================================================

import { type SupabaseClient } from "./supabase.ts";

const META_API_VERSION = "v21.0";

export interface OutboundContext {
  /** Log prefix of the calling function, e.g. "send-renewal-reminder". */
  tag: string;
  memberId?: string | null;
  organizationId?: string | null;
  templateName?: string | null;
  relatedPaymentId?: string | null;
}

export interface SendResult {
  /** Row id of the whatsapp_messages audit row, or null if logging failed. */
  messageId: string | null;
  status: "queued" | "sent" | "failed";
  /** False when the audit row could not be written — see the callers' notes. */
  logged: boolean;
}

/**
 * An approved WhatsApp message template call. `bodyParams` are positional —
 * index 0 fills {{1}} in the template body, index 1 fills {{2}}, and so on.
 * `language` is a Meta locale code (e.g. "en_GB" for "English (UK)"), not a
 * bare ISO-639 code — Meta rejects "en" for a template registered under
 * "English (UK)".
 */
export interface TemplateSpec {
  name: string;
  language: string;
  bodyParams: string[];
}

function isMockMode(): boolean {
  return (Deno.env.get("WHATSAPP_SEND_MODE") ?? "").trim().toLowerCase() === "mock";
}

// Deliberate test-only hook. Mock mode otherwise always reports "queued" — the
// live Meta-rejection path (status:"failed") is unreachable without real
// credentials, so callers have no way to exercise their failed-send handling
// under test (WHATSAPP_SEND_MODE=mock is mandatory for every test.sh). Sending
// to exactly this number makes mock mode simulate a failed send instead. Not a
// real phone shape (real numbers passed through this codebase are 12-digit
// `91...`), so it can never collide with a seeded fixture.
export const MOCK_FAILURE_PHONE = "0000000000";

/**
 * Call the real Meta Cloud API. Never throws — a Meta outage or a bad token
 * must not crash a caller mid-loop (send-renewal-reminder, daily-owner-brief
 * both send to many recipients per invocation).
 */
async function callMetaApi(
  tag: string,
  phone: string,
  text: string,
  template?: TemplateSpec,
): Promise<{ waMessageId: string | null; status: "sent" | "failed" }> {
  const accessToken = Deno.env.get("META_ACCESS_TOKEN");
  const phoneNumberId = Deno.env.get("META_PHONE_NUMBER_ID");

  if (!accessToken || !phoneNumberId) {
    console.error(
      `[${tag}] CRITICAL: META_ACCESS_TOKEN / META_PHONE_NUMBER_ID not set — cannot send.`,
    );
    return { waMessageId: null, status: "failed" };
  }

  const payload = template
    ? {
      messaging_product: "whatsapp",
      recipient_type: "individual",
      to: phone,
      type: "template",
      template: {
        name: template.name,
        language: { code: template.language },
        components: [
          {
            type: "body",
            parameters: template.bodyParams.map((p) => ({ type: "text", text: p })),
          },
        ],
      },
    }
    : {
      messaging_product: "whatsapp",
      recipient_type: "individual",
      to: phone,
      type: "text",
      text: { preview_url: false, body: text },
    };

  try {
    const res = await fetch(
      `https://graph.facebook.com/${META_API_VERSION}/${phoneNumberId}/messages`,
      {
        method: "POST",
        headers: {
          authorization: `Bearer ${accessToken}`,
          "content-type": "application/json",
        },
        body: JSON.stringify(payload),
      },
    );

    const result = await res.json().catch(() => null);

    if (res.ok) {
      const waMessageId = result?.messages?.[0]?.id ?? null;
      return { waMessageId, status: "sent" };
    }

    console.error(`[${tag}] Meta send failed (HTTP ${res.status}):`, result);
    return { waMessageId: null, status: "failed" };
  } catch (err) {
    console.error(
      `[${tag}] Meta send threw:`,
      err instanceof Error ? err.message : err,
    );
    return { waMessageId: null, status: "failed" };
  }
}

/**
 * Send a WhatsApp message to `phone` and record it in whatsapp_messages.
 *
 * Never throws: a send or logging failure must not roll back work that
 * already happened upstream (a captured payment, a created payment link).
 * Callers that care get `status: "failed"` / `logged: false` back and can
 * surface it.
 */
export async function sendWhatsAppMessage(
  supabase: SupabaseClient,
  phone: string | null,
  text: string,
  context: OutboundContext,
  template?: TemplateSpec,
): Promise<SendResult> {
  const { tag } = context;
  let waMessageId: string | null = null;
  let status: SendResult["status"];

  if (!phone) {
    // Nobody to deliver to — this is a failure to send, not a queued send.
    console.warn(
      `[${tag}] no phone on file for this member — logging the message but ` +
        "there is nobody to deliver it to.",
    );
    status = "failed";
  } else if (isMockMode()) {
    if (phone === MOCK_FAILURE_PHONE) {
      console.log(
        `[${tag}] WHATSAPP_SEND_MODE=mock — simulating a FAILED send (magic ` +
          `phone ${MOCK_FAILURE_PHONE}). ${
          template
            ? `template=${template.name} params=${JSON.stringify(template.bodyParams)}`
            : `text=${JSON.stringify(text)}`
        }`,
      );
      status = "failed";
    } else {
      console.log(
        `[${tag}] WHATSAPP_SEND_MODE=mock — not calling Meta. to=${phone} ${
          template
            ? `template=${template.name} params=${JSON.stringify(template.bodyParams)}`
            : `text=${JSON.stringify(text)}`
        }`,
      );
      status = "queued";
    }
  } else {
    const outcome = await callMetaApi(tag, phone, text, template);
    waMessageId = outcome.waMessageId;
    status = outcome.status;
  }

  const { data, error } = await supabase
    .from("whatsapp_messages")
    .insert({
      organization_id: context.organizationId ?? null,
      member_id: context.memberId ?? null,
      direction: "outbound",
      template_name: context.templateName ?? null,
      body_preview: text,
      wa_message_id: waMessageId,
      status,
      related_payment_id: context.relatedPaymentId ?? null,
    })
    .select("id")
    .single();

  if (error) {
    console.error(`[${tag}] failed to log outbound message:`, error);
    return { messageId: null, status, logged: false };
  }

  return { messageId: data.id, status, logged: true };
}
