// Shared outbound WhatsApp helper — THE ONE PLACE TO SWAP IN THE REAL META API.
//
// ============================================================================
// SIMULATION MODE
// ============================================================================
// We do NOT have Meta WhatsApp Business API credentials yet. Every outbound
// message is therefore "sent" by sendWhatsAppMessage() below, which currently
// only console.log()s inside the BEGIN/END SIMULATED SEND fence and writes a
// whatsapp_messages row with status 'queued'.
//
// The whatsapp_messages row is REAL either way — it is the outbound audit log,
// and send-renewal-reminder additionally uses it as its once-per-day guard.
//
// NOTE ON DUPLICATION: whatsapp-webhook/index.ts and razorpay-webhook/index.ts
// still carry their own copy of this helper (they predate this file and both
// are working, so they were deliberately left untouched). Until they are
// migrated there are three copies of the fence — all three are found by:
//   rg 'BEGIN SIMULATED SEND' supabase/functions
// Migrating them is a mechanical change: delete the local helper, import this
// one, and pass `tag`. See the note in the chat/README before doing it.
// ============================================================================

import { type SupabaseClient } from "./supabase.ts";

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
 * "Send" a WhatsApp message to `phone` and record it in whatsapp_messages.
 *
 * TODO(meta): SIMULATED. Replace the fenced block below with the real Cloud API
 * POST when credentials land — no caller needs to change.
 *
 * Never throws: a logging failure must not roll back work that already
 * happened upstream (a captured payment, a created payment link). Callers that
 * care get `logged: false` back and can surface it.
 */
export async function sendWhatsAppMessage(
  supabase: SupabaseClient,
  phone: string | null,
  text: string,
  context: OutboundContext,
): Promise<SendResult> {
  const { tag } = context;
  let waMessageId: string | null = null;
  let status: SendResult["status"] = "queued";

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
  //     console.error(`[${tag}] Meta send failed`, res.status, result);
  //   }
  //
  // NOTE: a renewal reminder and a payment confirmation are both
  // business-initiated, so they fall OUTSIDE Meta's 24h customer-service window
  // and must go out as APPROVED TEMPLATES, not free-form text. That is what
  // `templateName` is staged for — 'renewal_reminder' needs registering at Meta.
  if (!phone) {
    console.warn(
      `[${tag}] no phone on file for this member — logging the message but ` +
        "there is nobody to deliver it to.",
    );
  }
  console.log(
    `[${tag}] SIMULATED SEND -> to=${phone ?? "(unknown)"} text=${
      JSON.stringify(text)
    }`,
  );
  // ----------------- END SIMULATED SEND — REPLACE THIS BLOCK -----------------

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
