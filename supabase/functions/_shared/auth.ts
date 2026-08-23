// Shared caller authentication for the INTERNAL (non-webhook) Edge Functions.
//
// ============================================================================
// WHY verify_jwt = true IS NOT ENOUGH ON ITS OWN
// ============================================================================
// The two webhook functions authenticate the CALLER with an HMAC signature,
// because an external provider is signing the payload (see ./crypto.ts).
// send-renewal-reminder and renewal-scan have no external provider — they are
// called by our own code — so the gate is the Supabase JWT instead.
//
// But `verify_jwt = true` accepts the ANON key, and the anon key is public in
// every client app that ships. On endpoints that spend real money (renewal-scan
// fans out to send-renewal-reminder, which creates live Razorpay payment links)
// that would let anyone with a browser trigger a billing run.
//
// So these functions additionally require the SERVICE ROLE key, which only
// trusted server-side callers hold: pg_cron via Vault, function-to-function
// calls, and curl-based testing.
//
// NOTE ON DUPLICATION: send-renewal-reminder/index.ts still carries its own
// inline copy of this check (it predates this file and its suite is green, so
// it was deliberately left untouched). Migrating it is a mechanical change:
// delete the local `authorize()` and `AuthVerdict`, and import from here.
// ============================================================================

import { timingSafeEqualHex } from "./crypto.ts";

export type AuthVerdict = "ok" | "unauthorized" | "misconfigured";

/**
 * The service role key this deployment expects callers to present.
 *
 * SUPABASE_SERVICE_ROLE_KEY is the legacy name, SUPABASE_SECRET_KEY the newer
 * one. Both are injected automatically by the edge runtime; preferring the
 * legacy name keeps this identical to createAdminClient() in ./supabase.ts and
 * to the inline check in send-renewal-reminder.
 */
export function expectedServiceRoleKey(): string | null {
  return Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ??
    Deno.env.get("SUPABASE_SECRET_KEY") ?? null;
}

/**
 * Require the service role key in `Authorization: Bearer ...` (or `apikey`).
 *
 * Returns "misconfigured" rather than "unauthorized" when the environment has
 * no key at all, so the caller can answer 500 instead of 401 — a 401 there
 * would send an operator hunting for a credential problem on the WRONG side of
 * the call.
 */
export function authorizeServiceRole(req: Request, tag: string): AuthVerdict {
  const expected = expectedServiceRoleKey();

  if (!expected) {
    // Both names are injected by the edge runtime, so this means the
    // environment is broken — createAdminClient() would throw next anyway.
    console.error(
      `[${tag}] CRITICAL: no SUPABASE_SERVICE_ROLE_KEY / SUPABASE_SECRET_KEY ` +
        "in the environment; cannot authenticate callers.",
    );
    return "misconfigured";
  }

  const bearer = (req.headers.get("authorization") ?? "")
    .replace(/^bearer\s+/i, "").trim();
  const provided = bearer || (req.headers.get("apikey") ?? "").trim();

  if (!provided) return "unauthorized";

  // timingSafeEqualHex compares char-by-char over the full string; the name
  // reflects its usual callers (hex digests) but it is correct for any pair of
  // same-length ASCII strings, JWTs included.
  return timingSafeEqualHex(provided, expected) ? "ok" : "unauthorized";
}
