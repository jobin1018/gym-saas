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
// NOTE ON DUPLICATION: whatsapp-webhook/index.ts carries its own copy of this
// helper with the same WHATSAPP_SEND_MODE handling (they predate this file and
// both are working, so they were deliberately left untouched as separate
// copies). razorpay-webhook/index.ts's copy is UNCHANGED and still simulated —
// payment confirmation sends were not part of this migration; its own
// BEGIN/END SIMULATED SEND fence is still there and still accurate for that
// function specifically:
//   rg 'BEGIN SIMULATED SEND' supabase/functions
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

function isMockMode(): boolean {
  return (Deno.env.get("WHATSAPP_SEND_MODE") ?? "").trim().toLowerCase() === "mock";
}

/**
 * Call the real Meta Cloud API. Never throws — a Meta outage or a bad token
 * must not crash a caller mid-loop (send-renewal-reminder, daily-owner-brief
 * both send to many recipients per invocation).
 */
async function callMetaApi(
  tag: string,
  phone: string,
  text: string,
): Promise<{ waMessageId: string | null; status: "sent" | "failed" }> {
  const accessToken = Deno.env.get("META_ACCESS_TOKEN");
  const phoneNumberId = Deno.env.get("META_PHONE_NUMBER_ID");

  if (!accessToken || !phoneNumberId) {
    console.error(
      `[${tag}] CRITICAL: META_ACCESS_TOKEN / META_PHONE_NUMBER_ID not set — cannot send.`,
    );
    return { waMessageId: null, status: "failed" };
  }

  // TODO(meta): every send below goes out as "type":"text" (free-form),
  // REGARDLESS of context.templateName. That is temporary. Meta requires an
  // APPROVED MESSAGE TEMPLATE for any business-initiated message outside the
  // 24h customer-service window opened by an inbound message from the
  // customer — which is exactly what renewal_reminder and daily_owner_brief
  // are. No templates are approved in Meta Business Manager yet, so free-form
  // text is used here deliberately, to allow testing real delivery today. This
  // will start failing at Meta's end for real customers once their 24h window
  // (if any) has closed. Switch to a template call the moment one is approved:
  //
  //   body: JSON.stringify({
  //     messaging_product: "whatsapp",
  //     to: phone,
  //     type: "template",
  //     template: { name: context.templateName, language: { code: "en" } },
  //   })
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
    console.log(
      `[${tag}] WHATSAPP_SEND_MODE=mock — not calling Meta. to=${phone} text=${
        JSON.stringify(text)
      }`,
    );
    status = "queued";
  } else {
    const outcome = await callMetaApi(tag, phone, text);
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
