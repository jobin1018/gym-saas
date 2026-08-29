-- Add the 'coach' staff role, and add a `user_id` claim to every minted token.
--
-- ============================================================================
-- WHY THESE TWO CHANGES TRAVEL TOGETHER
-- ============================================================================
-- The coaching feature (pt_packages / training_notes / body_measurements, see
-- the three migrations that follow this one) scopes a coach's access by
-- ASSIGNMENT — "can this coach touch this member" is answered by
-- "does an active pt_packages row link them", not by org+location the way
-- front_desk works. Answering that inside an RLS policy needs the caller's
-- OWN public.users.id available on the token, because pt_packages.coach_id
-- references public.users(id).
--
-- The existing hook (20260824140000_create_custom_access_token_hook.sql)
-- already stamps org_id / app_role / location_id but NOT the row's id. The
-- JWT's built-in `sub` claim is auth.users.id (the GoTrue bridge row minted
-- by staff-login), which is a DIFFERENT value from public.users.id and is not
-- what any FK in this schema points at. So we add an explicit `user_id` claim
-- carrying public.users.id.
--
-- Naming: `user_id`, deliberately NOT overloading `sub`. Same disambiguation
-- reasoning as `app_role` vs `role` in the original hook — the platform
-- already has a claim with a fixed meaning (`sub` = auth user), so our
-- application identifier gets its own name rather than shadowing it.
--
-- 'coach' role: coaches ARE stored with a location_id (their home branch,
-- same shape as front_desk — org-chart consistency, and it still flows onto
-- the token). But NO RLS policy for the coaching tables reads that
-- location_id: a coach's client list follows assignment across the whole org,
-- not their branch. See 20260829091500 for the policies and the companion
-- hardening of memberships/attendance/whatsapp_messages that this new third
-- role makes necessary.
--
-- ============================================================================
-- FORWARD/BACKWARD COMPAT
-- ============================================================================
-- Adding `user_id` to the claims is purely additive — every existing policy
-- ignores it, and the frontend's claim decoder ignores unknown keys. The
-- "user not found" early-return path below still returns the event with
-- claims UNCHANGED (no user_id, exactly as it carries no org_id today); the
-- coach policies treat a missing user_id claim as NULL and deny cleanly, the
-- same fail-closed behaviour the original hook migration documents at length.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. users.role — add 'coach'
-- ---------------------------------------------------------------------------
-- Constraint name confirmed via pg_constraint: the inline CHECK in
-- 20260822041613_create_core_schema.sql was auto-named `users_role_check`.
ALTER TABLE public.users DROP CONSTRAINT users_role_check;
ALTER TABLE public.users ADD CONSTRAINT users_role_check
  CHECK (role IN ('owner', 'front_desk', 'coach'));

-- ---------------------------------------------------------------------------
-- 2. custom_access_token_hook — byte-for-byte the 20260824140000 body, plus
--    the single new jsonb_set for user_id. Re-declared in full (not ALTERed)
--    so this file is the readable source of truth for what the hook does
--    after this migration.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.custom_access_token_hook(event jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_auth_user_id uuid;
  v_row          public.users%ROWTYPE;
  v_claims       jsonb;
BEGIN
  v_claims := event->'claims';

  BEGIN
    v_auth_user_id := (event->>'user_id')::uuid;
  EXCEPTION WHEN invalid_text_representation THEN
    RETURN event;
  END;

  SELECT * INTO v_row FROM public.users WHERE auth_user_id = v_auth_user_id;

  IF NOT FOUND THEN
    RETURN event; -- see the FAIL CLOSED note in 20260824140000
  END IF;

  v_claims := jsonb_set(v_claims, '{org_id}', to_jsonb(v_row.organization_id::text));

  -- public.users.id — the value pt_packages.coach_id / training_notes.coach_id
  -- / body_measurements.recorded_by all reference. NOT the same as `sub`
  -- (auth.users.id). See this migration's header for why it needs its own
  -- claim name.
  v_claims := jsonb_set(v_claims, '{user_id}', to_jsonb(v_row.id::text));

  -- Named app_role, NOT "role" — Supabase's own JWT already has a top-level
  -- `role` claim PostgREST reads to pick the Postgres connection role.
  v_claims := jsonb_set(v_claims, '{app_role}', to_jsonb(v_row.role));

  -- ABSENT (key removed), not JSON null, for a user with no location_id
  -- (owners). ->>'location_id' on an absent key yields SQL NULL; on JSON null
  -- it yields the string "null" and ('null')::uuid raises.
  IF v_row.location_id IS NOT NULL THEN
    v_claims := jsonb_set(v_claims, '{location_id}', to_jsonb(v_row.location_id::text));
  ELSE
    v_claims := v_claims - 'location_id';
  END IF;

  RETURN jsonb_set(event, '{claims}', v_claims);
END;
$$;

COMMENT ON FUNCTION public.custom_access_token_hook(jsonb) IS
  'Supabase Auth "Customize Access Token" hook. Injects org_id / user_id / '
  'app_role / location_id claims from public.users, keyed by auth_user_id. '
  'user_id is public.users.id (what the app FKs reference), distinct from '
  'sub (auth.users.id). Returns the event with claims UNCHANGED for any '
  'user_id that does not resolve to a bridged public.users row — fail-closed, '
  'see 20260824140500_rewrite_tenant_isolation_policies_for_jwt.sql.';

-- CREATE OR REPLACE preserves existing privileges, but re-assert them so this
-- file stands alone — same idempotent tail as 20260824140000.
REVOKE ALL ON FUNCTION public.custom_access_token_hook(jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.custom_access_token_hook(jsonb) FROM anon, authenticated, service_role;
GRANT USAGE ON SCHEMA public TO supabase_auth_admin;
GRANT EXECUTE ON FUNCTION public.custom_access_token_hook(jsonb) TO supabase_auth_admin;
