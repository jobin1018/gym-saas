// claim-paid — PUBLIC (verify_jwt = false), rate limited.
//
// POST { "token": "<32 hex>" }   "I have paid"
//
// Stamps payment_requests.claimed_paid_at ONCE and logs it. That is all: it
// does NOT create a payment and does NOT extend any membership. Staff see the
// claim in list_pending_payment_claims() and confirm by recording the money
// with record_manual_payment(..., 'upi').

import "@supabase/functions-js/edge-runtime.d.ts";
import { createAdminClient } from "../_shared/supabase.ts";
import { CORS_HEADERS, corsJson, corsPreflightResponse } from "../_shared/cors.ts";
import { allowRequest, clientBucket, readToken } from "../_shared/pay-page.ts";

const TAG = "claim-paid";

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return corsPreflightResponse();
  if (req.method !== "POST") return corsJson({ ok: false, error: "method_not_allowed" }, 405);

  try {
    const supabase = createAdminClient();

    if (!(await allowRequest(supabase, await clientBucket(req, "claim")))) {
      return new Response(JSON.stringify({ ok: false, error: "rate_limited" }), {
        status: 429,
        headers: { "content-type": "application/json", "retry-after": "60", ...CORS_HEADERS },
      });
    }

    const token = await readToken(req);
    if (!token) return corsJson({ ok: false, error: "not_found" }, 404);

    const { data, error } = await supabase.rpc("claim_payment_request", { p_token: token });
    if (error) throw error;
    const row = Array.isArray(data) ? data[0] : data;

    switch (row?.outcome) {
      case "claimed":
        console.log(
          `[${TAG}] CLAIM request=${row.request_id} org=${row.organization_id} at=${row.claimed_paid_at}`,
        );
        return corsJson({ ok: true, status: "claimed", claimed_paid_at: row.claimed_paid_at });
      case "already_claimed":
        return corsJson({ ok: true, status: "already_claimed", claimed_paid_at: row.claimed_paid_at });
      case "org_inactive":
        return corsJson({ ok: false, error: "organization_inactive" }, 403);
      default:
        return corsJson({ ok: false, error: "not_found" }, 404);
    }
  } catch (err) {
    console.error(`[${TAG}] failed:`, err);
    return corsJson({ ok: false, error: "internal_error" }, 500);
  }
});
