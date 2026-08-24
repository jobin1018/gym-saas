-- Custom access-token hook — injects org_id / app_role / location_id claims
-- onto every token Supabase Auth issues or refreshes.
--
-- ============================================================================
-- WHY THIS EXISTS
-- ============================================================================
-- staff-login (see supabase/functions/staff-login/index.ts) mints a real
-- Supabase Auth session for a bridged public.users row, but a bare session
-- carries nothing tenant-specific — no org, no role, no location. Every RLS
-- policy in this schema (see the companion migration
-- 20260824140500_rewrite_tenant_isolation_policies_for_jwt.sql) reads those
-- three things off the token via auth.jwt(), so this hook is what actually
-- puts them there. Called automatically by GoTrue on every sign-in and every
-- token refresh — not something any client code invokes directly.
--
-- ============================================================================
-- FAIL CLOSED, NOT FAIL LOUD — the "user not found" case
-- ============================================================================
-- If event->>'user_id' does not resolve to a public.users row (the bridging
-- row was deleted after a session was minted but before it expired, or —
-- should never happen given how auth.users rows are only ever created by
-- ensureAuthUser() — some other auth.users row entirely), this function
-- returns the event with its claims UNCHANGED. That is deliberate:
--
--   auth.jwt()->>'org_id'   on a token with no such claim  ->  SQL NULL
--   NULL::uuid                                              ->  SQL NULL
--   organization_id = NULL                                  ->  NULL (not true)
--
-- USING/WITH CHECK treat NULL as false, so every rewritten policy denies
-- cleanly — zero rows, no error — rather than the request 500ing. This was
-- verified directly against this project's local Postgres, not assumed.
--
-- There is deliberately NO catch-all exception handler around the body below
-- that would turn a genuinely unexpected error (e.g. a future migration
-- renaming a column this function reads) into another claimless token. That
-- kind of failure should be loud — it means token issuance itself is broken —
-- not silently downgraded into "logs in but can't see anything."
-- ============================================================================

CREATE OR REPLACE FUNCTION public.custom_access_token_hook(event jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
-- Pinned search_path: SECURITY DEFINER and reads public.users, so it must not
-- resolve `users` through a caller-controlled search_path. Same discipline as
-- trigger_renewal_scan() in 20260823130500_schedule_renewal_scan_cron.sql,
-- narrower here since this function needs no vault/extensions access.
SET search_path = public, pg_temp
AS $$
DECLARE
  v_auth_user_id uuid;
  v_row          public.users%ROWTYPE;
  v_claims       jsonb;
BEGIN
  v_claims := event->'claims';

  -- A malformed/absent user_id should never happen per GoTrue's documented
  -- hook contract, but a cast failure here must not become an unhandled
  -- exception over a narrow parsing reason unrelated to who the user is.
  BEGIN
    v_auth_user_id := (event->>'user_id')::uuid;
  EXCEPTION WHEN invalid_text_representation THEN
    RETURN event;
  END;

  SELECT * INTO v_row FROM public.users WHERE auth_user_id = v_auth_user_id;

  IF NOT FOUND THEN
    RETURN event; -- see the FAIL CLOSED note above
  END IF;

  v_claims := jsonb_set(v_claims, '{org_id}', to_jsonb(v_row.organization_id::text));

  -- Named app_role, NOT "role" — Supabase's own JWT already has a top-level
  -- `role` claim (anon/authenticated/service_role) that PostgREST reads to
  -- pick the Postgres connection role for the request. Overwriting it with
  -- 'owner'/'front_desk' would make PostgREST try to connect as a Postgres
  -- role that does not exist and break every request outright, not just
  -- misbehave.
  v_claims := jsonb_set(v_claims, '{app_role}', to_jsonb(v_row.role));

  -- ABSENT (key removed), not JSON null, for an owner (location_id NULL in
  -- the users row). ->>'location_id' on an absent key yields SQL NULL; on a
  -- present key holding JSON null it yields the 4-character STRING "null",
  -- and ('null')::uuid raises — exactly the exception-on-cast failure mode
  -- this whole design exists to avoid. So the key must be removed entirely,
  -- not set to null.
  IF v_row.location_id IS NOT NULL THEN
    v_claims := jsonb_set(v_claims, '{location_id}', to_jsonb(v_row.location_id::text));
  ELSE
    v_claims := v_claims - 'location_id';
  END IF;

  RETURN jsonb_set(event, '{claims}', v_claims);
END;
$$;

COMMENT ON FUNCTION public.custom_access_token_hook(jsonb) IS
  'Supabase Auth "Customize Access Token" hook. Injects org_id / app_role / '
  'location_id claims from public.users, keyed by auth_user_id. Returns the '
  'event with claims UNCHANGED for any user_id that does not resolve to a '
  'bridged public.users row — see 20260824140500_rewrite_tenant_isolation_'
  'policies_for_jwt.sql for the policies that depend on this and why that is '
  'fail-closed rather than an error.';

-- Only GoTrue (as supabase_auth_admin) ever calls this, invoked out-of-band
-- via pg-functions:// — never through PostgREST, and never something a
-- client or even service_role should call directly. Postgres's default
-- EXECUTE-to-PUBLIC still has to be revoked explicitly regardless. Same
-- discipline as trigger_renewal_scan()'s revoke block.
REVOKE ALL ON FUNCTION public.custom_access_token_hook(jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.custom_access_token_hook(jsonb) FROM anon, authenticated, service_role;

-- Both idempotent/re-runnable — safe across repeated `supabase db reset`s.
GRANT USAGE ON SCHEMA public TO supabase_auth_admin;
GRANT EXECUTE ON FUNCTION public.custom_access_token_hook(jsonb) TO supabase_auth_admin;
