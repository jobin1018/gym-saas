// The ONE place that decides how an organization's members pay a renewal.
//
//   1. No org_payment_settings row  -> "legacy gym": Razorpay, exactly as it
//      always was (including its hard failure when credentials are missing).
//   2. razorpay_enabled AND credentials exist           -> razorpay
//   3. qr_enabled AND qr_image_path AND upi_id          -> qr
//   4. otherwise                                        -> none (+ reason)
//
// "none" means: send nothing, record why (payment_link_skips) so the owner's
// ALERTS / v_payment_setup_alerts can flag it.
//
// Used by send-renewal-reminder. whatsapp-webhook's PAY intent reaches it
// through send-renewal-reminder (which it calls), so there is one rule, not two.

import { type SupabaseClient } from "./supabase.ts";

export type NoPaymentReason =
  | "no_payment_method_enabled"
  | "qr_enabled_but_incomplete"
  | "razorpay_credentials_missing"
  | "pay_page_url_not_configured";

export type PaymentMode =
  | { mode: "razorpay"; legacy: boolean }
  | { mode: "qr"; upiId: string; qrImagePath: string }
  | { mode: "none"; reason: NoPaymentReason };

/** RAZORPAY_MODE=mock needs no keys (tests); otherwise both keys must be set. */
export function razorpayCredentialsPresent(): boolean {
  if (razorpayIsMock()) return true;
  return !!Deno.env.get("RAZORPAY_KEY_ID") && !!Deno.env.get("RAZORPAY_KEY_SECRET");
}

export function razorpayIsMock(): boolean {
  return (Deno.env.get("RAZORPAY_MODE") ?? "").trim().toLowerCase() === "mock";
}

/** Base URL of the member-facing pay page (frontend), no trailing slash. */
export function payPageBase(): string | null {
  const base = (Deno.env.get("PAY_PAGE_BASE_URL") ?? "").trim().replace(/\/+$/, "");
  return base || null;
}

export function payPageUrl(token: string): string | null {
  const base = payPageBase();
  return base ? `${base}/${token}` : null;
}

export async function decidePaymentMode(
  supabase: SupabaseClient,
  organizationId: string,
): Promise<PaymentMode> {
  const { data, error } = await supabase
    .from("org_payment_settings")
    .select("upi_id,qr_image_path,qr_enabled,razorpay_enabled")
    .eq("organization_id", organizationId)
    .maybeSingle();
  if (error) throw error;

  if (!data) return { mode: "razorpay", legacy: true };

  if (data.razorpay_enabled && razorpayCredentialsPresent()) {
    return { mode: "razorpay", legacy: false };
  }

  if (data.qr_enabled) {
    if (!data.qr_image_path || !data.upi_id) {
      return { mode: "none", reason: "qr_enabled_but_incomplete" };
    }
    if (!payPageBase()) return { mode: "none", reason: "pay_page_url_not_configured" };
    return { mode: "qr", upiId: data.upi_id, qrImagePath: data.qr_image_path };
  }

  return {
    mode: "none",
    reason: data.razorpay_enabled ? "razorpay_credentials_missing" : "no_payment_method_enabled",
  };
}

/** Record that a reminder was not sent for want of a payment method. */
export async function recordPaymentSkip(
  supabase: SupabaseClient,
  organizationId: string,
  membershipId: string | null,
  reason: NoPaymentReason,
): Promise<void> {
  const { error } = await supabase.from("payment_link_skips").insert({
    organization_id: organizationId,
    membership_id: membershipId,
    reason,
  });
  if (error) console.error("[payment-mode] failed to record skip:", error);
}
