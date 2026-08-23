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
