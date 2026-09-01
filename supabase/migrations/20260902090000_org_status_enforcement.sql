-- Platform-subscription enforcement: a 'suspended' organization is frozen.
--
-- ============================================================================
-- WHAT CHANGES
-- ============================================================================
-- organizations.status has existed since the core schema (trial|active|
-- suspended) but nothing read it for access control — a suspended org's owner
-- logged in and used everything normally. This migration makes 'suspended'
-- actually mean "frozen":
--
--   1. current_org_active() — one SECURITY DEFINER check of the caller's org
--      status, evaluated ONCE per query (STABLE, no args), same helper pattern
--      as pt_active_assignment_exists / custom_access_token_hook.
--
--   2. A RESTRICTIVE policy `org_not_suspended` on every tenant-scoped table
--      that has RLS. RESTRICTIVE policies AND with the existing permissive
--      tenant_isolation_* policies, so this adds "... AND the org is not
--      suspended" to both USING and WITH CHECK on every table WITHOUT
--      rewriting any of the (large, carefully-reasoned) permissive bodies.
--      Effect is IMMEDIATE — it re-reads live organizations.status on every
--      query, so an already-issued access token stops seeing rows the moment
--      the org is suspended, no token refresh needed.
--
--   3. custom_access_token_hook also strips every tenant claim when the org is
--      suspended — identical treatment to a deactivated user. This makes a
--      REFRESHED token inert too (defense in depth; (2) already covers the
--      pre-refresh window).
--
-- Tables NOT given the policy, and why:
--   * login_attempts, member_active_context, webhook_events — RLS is OFF;
--     only service_role (BYPASSRLS) ever touches them. The suspended-org gate
--     for the one that matters (login_attempts) is enforced in staff-login
--     itself (it refuses a suspended org's PIN before minting a session).
--   * coach_magic_links — RLS on, NO permissive policy => already deny-all for
--     anon/authenticated. A magic link minted before suspension still
--     validates, but the coach session it produces then hits the RESTRICTIVE
--     policy on members / training_notes / body_measurements and gets a clean
--     RLS denial (see log_session below).
--
-- ============================================================================
-- FLIPPING AN ORG FOR TESTING
-- ============================================================================
--   UPDATE public.organizations SET status = 'suspended' WHERE id = '<org>';
--   UPDATE public.organizations SET status = 'active'    WHERE id = '<org>';
-- That single column flip IS sufficient. current_org_active() reads it live on
-- every query, so suspending takes effect on the next request against any
-- already-open session, and reactivating restores full access with no other
-- action (no re-login, no cache bust). staff-login re-checks it per attempt.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- The helper. SECURITY DEFINER so it reads organizations without re-entering
-- that table's own RLS (no recursion, even for the policy we add to
-- organizations itself). STABLE + zero args => the planner evaluates it once
-- per statement, not per row — this is the performance answer to "don't put a
-- correlated subquery on every policy".
--
-- Returns FALSE when the caller has no org_id claim (anon, or a claims-
-- stripped token): auth.jwt() ->> 'org_id' is NULL, NULL::uuid matches no row,
-- EXISTS is false. Fail-closed, same as the permissive policies' NULL handling.
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.current_org_active()
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public, pg_temp
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.organizations
     WHERE id = (auth.jwt() ->> 'org_id')::uuid
       AND status IN ('trial', 'active')
  );
$$;

REVOKE ALL ON FUNCTION public.current_org_active() FROM PUBLIC;
-- RLS predicates run as the querying role, so both roles must be able to call
-- it. anon still gets nothing everywhere (no org_id claim => returns false).
GRANT EXECUTE ON FUNCTION public.current_org_active() TO anon, authenticated;

-- ---------------------------------------------------------------------------
-- The RESTRICTIVE gate, one per tenant-scoped RLS table. FOR ALL + both USING
-- and WITH CHECK so it covers SELECT / INSERT / UPDATE / DELETE uniformly.
-- ---------------------------------------------------------------------------
CREATE POLICY org_not_suspended ON public.organizations
  AS RESTRICTIVE FOR ALL TO public
  USING (public.current_org_active()) WITH CHECK (public.current_org_active());

CREATE POLICY org_not_suspended ON public.locations
  AS RESTRICTIVE FOR ALL TO public
  USING (public.current_org_active()) WITH CHECK (public.current_org_active());

CREATE POLICY org_not_suspended ON public.users
  AS RESTRICTIVE FOR ALL TO public
  USING (public.current_org_active()) WITH CHECK (public.current_org_active());

CREATE POLICY org_not_suspended ON public.members
  AS RESTRICTIVE FOR ALL TO public
  USING (public.current_org_active()) WITH CHECK (public.current_org_active());

CREATE POLICY org_not_suspended ON public.membership_plans
  AS RESTRICTIVE FOR ALL TO public
  USING (public.current_org_active()) WITH CHECK (public.current_org_active());

CREATE POLICY org_not_suspended ON public.memberships
  AS RESTRICTIVE FOR ALL TO public
  USING (public.current_org_active()) WITH CHECK (public.current_org_active());

CREATE POLICY org_not_suspended ON public.payments
  AS RESTRICTIVE FOR ALL TO public
  USING (public.current_org_active()) WITH CHECK (public.current_org_active());

CREATE POLICY org_not_suspended ON public.attendance
  AS RESTRICTIVE FOR ALL TO public
  USING (public.current_org_active()) WITH CHECK (public.current_org_active());

CREATE POLICY org_not_suspended ON public.whatsapp_messages
  AS RESTRICTIVE FOR ALL TO public
  USING (public.current_org_active()) WITH CHECK (public.current_org_active());

CREATE POLICY org_not_suspended ON public.pt_packages
  AS RESTRICTIVE FOR ALL TO public
  USING (public.current_org_active()) WITH CHECK (public.current_org_active());

CREATE POLICY org_not_suspended ON public.training_notes
  AS RESTRICTIVE FOR ALL TO public
  USING (public.current_org_active()) WITH CHECK (public.current_org_active());

CREATE POLICY org_not_suspended ON public.body_measurements
  AS RESTRICTIVE FOR ALL TO public
  USING (public.current_org_active()) WITH CHECK (public.current_org_active());

-- ---------------------------------------------------------------------------
-- log_session (coach session-logging RPC, SECURITY INVOKER) — turn the
-- RESTRICTIVE-policy denial a suspended org would hit on the training_notes
-- INSERT into an explicit, readable error instead of a bare
-- "new row violates row-level security policy". Everything else about the
-- function is unchanged.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.log_session(
  p_member_id uuid, p_pt_package_id uuid, p_note_text text,
  p_session_date date DEFAULT CURRENT_DATE,
  p_weight_kg numeric DEFAULT NULL::numeric,
  p_height_cm numeric DEFAULT NULL::numeric)
RETURNS TABLE(training_note_id uuid, body_measurement_id uuid,
             sessions_used integer, sessions_purchased integer, package_status text)
LANGUAGE plpgsql
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_org     uuid := (auth.jwt() ->> 'org_id')::uuid;
  v_coach   uuid := (auth.jwt() ->> 'user_id')::uuid;
  v_note_id uuid;
  v_bm_id   uuid;
BEGIN
  IF v_org IS NULL OR v_coach IS NULL THEN
    RAISE EXCEPTION 'log_session requires an authenticated staff session';
  END IF;

  -- Suspended org: the training_notes INSERT below would fail the
  -- org_not_suspended RESTRICTIVE policy anyway; say so plainly.
  IF NOT public.current_org_active() THEN
    RAISE EXCEPTION 'organization is suspended — session logging is disabled'
      USING errcode = 'P0001';
  END IF;

  IF p_note_text IS NULL OR btrim(p_note_text) = '' THEN
    RAISE EXCEPTION 'note_text is required';
  END IF;

  IF (p_weight_kg IS NULL) <> (p_height_cm IS NULL) THEN
    RAISE EXCEPTION 'weight_kg and height_cm must be provided together or both omitted';
  END IF;

  INSERT INTO public.training_notes
    (organization_id, member_id, coach_id, pt_package_id, note_text, session_date)
  VALUES
    (v_org, p_member_id, v_coach, p_pt_package_id, p_note_text,
     COALESCE(p_session_date, CURRENT_DATE))
  RETURNING id INTO v_note_id;

  IF p_weight_kg IS NOT NULL THEN
    INSERT INTO public.body_measurements
      (organization_id, member_id, recorded_by, weight_kg, height_cm, training_note_id)
    VALUES
      (v_org, p_member_id, v_coach, p_weight_kg, p_height_cm, v_note_id)
    RETURNING id INTO v_bm_id;
  END IF;

  RETURN QUERY
    SELECT v_note_id, v_bm_id, p.sessions_used, p.sessions_purchased, p.status
      FROM public.pt_packages p
     WHERE p.id = p_pt_package_id;
END;
$function$;

-- ---------------------------------------------------------------------------
-- custom_access_token_hook — strip every tenant claim for a suspended org,
-- exactly as it already does for a deactivated user. Belt-and-suspenders on
-- top of the RESTRICTIVE policies: a token refreshed after suspension comes
-- back with no org_id/app_role/user_id/location_id at all.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.custom_access_token_hook(event jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
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

  -- NOT FOUND (bridged row gone) OR the account has been deactivated: return
  -- the event with claims UNCHANGED. auth.jwt() ->> 'org_id' is then SQL NULL
  -- and every tenant_isolation_* policy denies cleanly — no error, zero rows.
  IF NOT FOUND OR NOT COALESCE(v_row.active, true) THEN
    RETURN event;
  END IF;

  -- Platform subscription on hold: same treatment as a deactivated user.
  IF NOT EXISTS (
    SELECT 1 FROM public.organizations
     WHERE id = v_row.organization_id
       AND status IN ('trial', 'active')
  ) THEN
    RETURN event;
  END IF;

  v_claims := jsonb_set(v_claims, '{org_id}', to_jsonb(v_row.organization_id::text));
  v_claims := jsonb_set(v_claims, '{user_id}', to_jsonb(v_row.id::text));
  v_claims := jsonb_set(v_claims, '{app_role}', to_jsonb(v_row.role));

  IF v_row.location_id IS NOT NULL THEN
    v_claims := jsonb_set(v_claims, '{location_id}', to_jsonb(v_row.location_id::text));
  ELSE
    v_claims := v_claims - 'location_id';
  END IF;

  RETURN jsonb_set(event, '{claims}', v_claims);
END;
$function$;

-- ---------------------------------------------------------------------------
-- staff_lookup_directory — surface the org's status so staff-lookup-by-phone
-- (pre-PIN) can hide / flag a suspended org's staff. Recreated because a view
-- column list cannot be altered in place. security_invoker unchanged.
-- ---------------------------------------------------------------------------
DROP VIEW public.staff_lookup_directory;
CREATE VIEW public.staff_lookup_directory
WITH (security_invoker = true) AS
SELECT
  u.id,
  u.organization_id,
  o.name   AS organization_name,
  o.status AS organization_status,
  u.phone,
  u.name,
  u.role
FROM public.users u
JOIN public.organizations o ON o.id = u.organization_id;

COMMENT ON VIEW public.staff_lookup_directory IS
  'Cross-organization phone -> staff lookup for staff-lookup-by-phone. '
  'Deliberately excludes pin_hash, location_id and everything else on users '
  'not needed to resolve/display a match. organization_status is included so '
  'the pre-PIN lookup can drop or flag a suspended org. service_role only.';

GRANT SELECT ON public.staff_lookup_directory TO service_role;
