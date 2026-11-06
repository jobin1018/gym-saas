// get-pay-page — PUBLIC (verify_jwt = false), rate limited.
//
// POST { "token": "<32 hex>" }
//
// Returns what the member-facing pay page needs and nothing else: gym name,
// plan, amount, UPI id, a short-lived signed URL for the QR image, which
// options are enabled, and the member's FIRST name. 404 for unknown or expired
// tokens (indistinguishable), 403 for a suspended gym, 429 when rate limited.
// Read-only: does not log a view, claim anything or touch money.

import "@supabase/functions-js/edge-runtime.d.ts";
import { createAdminClient } from "../_shared/supabase.ts";
import { CORS_HEADERS, corsJson, corsPreflightResponse } from "../_shared/cors.ts";
import { allowRequest, clientBucket, readToken } from "../_shared/pay-page.ts";
import { razorpayCredentialsPresent } from "../_shared/payment-mode.ts";

const TAG = "get-pay-page";
const QR_BUCKET = "payment-qr";
export const QR_URL_TTL_SECONDS = 300;

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return corsPreflightResponse();
  if (req.method !== "POST") return corsJson({ ok: false, error: "method_not_allowed" }, 405);

  try {
    const supabase = createAdminClient();

    if (!(await allowRequest(supabase, await clientBucket(req, "get"))) ) {
      return new Response(JSON.stringify({ ok: false, error: "rate_limited" }), {
        status: 429,
        headers: { "content-type": "application/json", "retry-after": "60", ...CORS_HEADERS },
      });
    }

    const token = await readToken(req);
    if (!token) return corsJson({ ok: false, error: "not_found" }, 404);

    const { data, error } = await supabase.rpc("get_pay_page_data", { p_token: token });
    if (error) throw error;
    const row = Array.isArray(data) ? data[0] : data;

    if (!row) return corsJson({ ok: false, error: "not_found" }, 404);
    if (!row.org_active) return corsJson({ ok: false, error: "organization_inactive" }, 403);
    // The gym has since turned QR payments off or removed its details: there is
    // nothing the member can pay with, so the link is dead.
    if (!row.qr_enabled || !row.upi_id || !row.qr_image_path) {
      return corsJson({ ok: false, error: "not_found" }, 404);
    }

    const { data: signed, error: signError } = await supabase.storage
      .from(QR_BUCKET)
      .createSignedUrl(row.qr_image_path, QR_URL_TTL_SECONDS);
    if (signError || !signed?.signedUrl) {
      console.error(`[${TAG}] could not sign QR for org ${row.organization_id}:`, signError);
    }

    return corsJson({
      ok: true,
      gym_name: row.gym_name,
      member_first_name: row.member_first_name,
      plan_name: row.plan_name,
      subject: row.subject,
      amount: Number(row.amount),
      currency: "INR",
      upi_id: row.upi_id,
      qr_url: signed?.signedUrl ?? null,
      qr_url_expires_in: QR_URL_TTL_SECONDS,
      options: {
        upi_qr: true,
        razorpay: !!row.razorpay_enabled && razorpayCredentialsPresent(),
      },
      claimed_paid: row.claimed_paid_at !== null,
      expires_at: row.expires_at,
    });
  } catch (err) {
    console.error(`[${TAG}] failed:`, err);
    return corsJson({ ok: false, error: "internal_error" }, 500);
  }
});
