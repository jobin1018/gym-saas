// Shared Supabase client helper for Edge Functions.
//
// IMPORTANT: we deliberately use the SERVICE ROLE key here.
//
// Every tenant table in 20260822041613_create_core_schema.sql has RLS enabled with
// policies of the form `organization_id = current_setting('app.current_org_id')::uuid`.
// A webhook has no authenticated user and no org context to set, and
// `current_setting()` on an unset key raises rather than returning NULL — so any
// non-bypassing role would error out. The service role bypasses RLS entirely, which
// is what a trusted server-to-server webhook handler needs.
//
// The trade-off: this client can see ALL tenants, so every query in a webhook MUST
// scope explicitly by organization_id / member_id once the tenant is resolved.

import { createClient, type SupabaseClient } from "@supabase/supabase-js";

export type { SupabaseClient };

export function createAdminClient(): SupabaseClient {
  const url = Deno.env.get("SUPABASE_URL");
  // SUPABASE_SERVICE_ROLE_KEY is the legacy name, SUPABASE_SECRET_KEY the newer one.
  // Both are injected automatically by the Supabase edge runtime (local and hosted).
  const secretKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ??
    Deno.env.get("SUPABASE_SECRET_KEY");

  if (!url || !secretKey) {
    throw new Error(
      "Missing SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY / SUPABASE_SECRET_KEY",
    );
  }

  return createClient(url, secretKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
}

/**
 * A client keyed on the ANON key, RLS fully in effect.
 *
 * staff-login needs this for exactly one call: `auth.verifyOtp()`, to redeem
 * the admin-generated magic-link token into a real session. That redemption
 * is a public GoTrue endpoint gated on `apikey` alone — using the anon key
 * here (rather than reusing createAdminClient()) keeps the distinction
 * between "server minting a link" (needs service_role) and "redeeming a
 * token" (does not) visible in the code, matching how the underlying GoTrue
 * REST API itself separates /admin/generate_link from /verify.
 */
export function createAnonClient(): SupabaseClient {
  const url = Deno.env.get("SUPABASE_URL");
  // Confirmed present under this exact name in the edge runtime env (unlike
  // the service-role key, there is no SUPABASE_INTERNAL_PUBLISHABLE_KEY
  // fallback needed here — verified via `docker exec ... env` rather than
  // assumed).
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY");

  if (!url || !anonKey) {
    throw new Error("Missing SUPABASE_URL or SUPABASE_ANON_KEY");
  }

  return createClient(url, anonKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
}

/**
 * A client authenticated as an already-minted session (an access_token from
 * mintSession()), for making PostgREST/RPC calls that must go through that
 * session's OWN RLS scope rather than service_role's unrestricted one.
 *
 * Used by whatsapp-webhook's owner/front_desk action commands (PAUSE MEMBER,
 * RESUME MEMBER, ADD MEMBER, ADD PT): those handlers mint a real session for
 * the resolved staff sender (same _shared/staff-session.ts bridge
 * validate-magic-link uses) and make every subsequent write through THIS
 * client, so tenant_isolation_* / freeze_membership / unfreeze_membership
 * enforce org + location scoping exactly as they would for a normal
 * PIN-logged-in session — no hand-written duplicate of that scoping logic
 * in whatsapp-webhook itself. The token is used only for the remainder of
 * that one request and is never returned to the WhatsApp sender.
 */
export function createSessionClient(accessToken: string): SupabaseClient {
  const url = Deno.env.get("SUPABASE_URL");
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY");

  if (!url || !anonKey) {
    throw new Error("Missing SUPABASE_URL or SUPABASE_ANON_KEY");
  }

  return createClient(url, anonKey, {
    auth: { persistSession: false, autoRefreshToken: false },
    global: { headers: { Authorization: `Bearer ${accessToken}` } },
  });
}
