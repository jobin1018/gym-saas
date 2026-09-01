-- users.active — soft-deactivate for staff, plus the view / hook / trigger
-- changes that make deactivation actually revoke access.
--
-- ============================================================================
-- WHY SOFT, NOT HARD DELETE
-- ============================================================================
-- public.users is referenced by pt_packages.coach_id, training_notes.coach_id,
-- body_measurements.recorded_by and attendance.marked_by. A DELETE would
-- orphan or block on those historical rows. `active = false` keeps the row
-- (and every FK to it) intact while removing the person's ability to act.
--
-- ============================================================================
-- HOW DEACTIVATION REVOKES ACCESS — three layers
-- ============================================================================
--  1. staff-login rejects a correct PIN for an inactive user (see that
--     function — `account_deactivated`, 403). No NEW session can be minted.
--  2. custom_access_token_hook below: an inactive user's next token issuance
--     OR refresh returns the event with claims UNCHANGED — no org_id /
--     app_role / user_id — so every RLS policy denies. This is what neuters an
--     EXISTING session; it takes effect at the next access-token refresh
--     (jwt_expiry = 3600s, so <= 1h worst case, usually much less because the
--     client refreshes proactively and the refreshed token is already dead).
--  3. staff-manage's `deactivate` action also calls
--     auth.admin.signOut(user, 'global'), killing the refresh token
--     immediately so layer 2 fires on the client's very next call.
-- The stateless access token itself cannot be invalidated mid-flight — that
-- residual <=1h window is the accepted exposure and is documented at the
-- staff-manage call site.
--
-- ============================================================================
-- VISIBILITY
-- ============================================================================
--  * staff_directory gains an `active` column and returns ALL staff. The
--    owner's Staff page filters active = true by default and drops that
--    filter for a "show inactive" toggle — one view, client-side switch,
--    rather than two views or a parameter.
--  * coaches_directory (the "assign a coach" dropdown) now filters
--    active = true — a deactivated coach must not be assignable to a new
--    package.
--  * pt_packages_validate_refs() gains the same check as defence in depth, so
--    a stale client that submits a deactivated coach's id is rejected at the
--    write, not just hidden in the dropdown.
--
-- No new GRANTs: `authenticated` already has SELECT on both views;
-- service_role already has what staff-manage needs on users / locations /
-- login_attempts. RLS on `users` itself is unchanged (still no
-- anon/authenticated grant — the views are the only browser-facing path).
-- ============================================================================

ALTER TABLE public.users ADD COLUMN active BOOLEAN NOT NULL DEFAULT true;

-- ---------------------------------------------------------------------------
-- custom_access_token_hook — byte-for-byte the 20260829090000 body plus the
-- single new "and active" gate. Re-declared in full so this file is the
-- readable source of truth for what the hook does now.
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

  -- NOT FOUND (bridged row gone) OR the account has been deactivated: return
  -- the event with claims UNCHANGED. auth.jwt() ->> 'org_id' is then SQL NULL
  -- and every tenant_isolation_* policy denies cleanly — no error, zero rows.
  -- This is the "revoke the existing session" mechanism for deactivation.
  IF NOT FOUND OR NOT COALESCE(v_row.active, true) THEN
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
$$;

COMMENT ON FUNCTION public.custom_access_token_hook(jsonb) IS
  'Supabase Auth "Customize Access Token" hook. Injects org_id / user_id / '
  'app_role / location_id from public.users, keyed by auth_user_id. Returns '
  'the event with claims UNCHANGED (fail-closed: RLS denies) for a user_id '
  'that does not resolve to a bridged row OR whose users.active is false.';

REVOKE ALL ON FUNCTION public.custom_access_token_hook(jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.custom_access_token_hook(jsonb) FROM anon, authenticated, service_role;
GRANT USAGE ON SCHEMA public TO supabase_auth_admin;
GRANT EXECUTE ON FUNCTION public.custom_access_token_hook(jsonb) TO supabase_auth_admin;

-- ---------------------------------------------------------------------------
-- staff_directory — add `active`, still owner-scoped, still definer-rights
-- (authenticated has no SELECT on users; a security_invoker view would fail
-- closed). Returns active AND inactive rows; the client filters.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.staff_directory AS
SELECT id, name, role, phone, active
FROM public.users
WHERE organization_id = ((auth.jwt() ->> 'org_id')::uuid)
  AND (auth.jwt() ->> 'app_role') = 'owner';

COMMENT ON VIEW public.staff_directory IS
  'Owner-only, org-scoped staff list for the Staff admin page. Includes '
  'deactivated users (active = false) — the page filters active = true by '
  'default and toggles that off for "show inactive".';

-- ---------------------------------------------------------------------------
-- coaches_directory — deactivated coaches drop out of the assign dropdown.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.coaches_directory AS
SELECT id, name
FROM public.users
WHERE role = 'coach'
  AND active
  AND organization_id = ((auth.jwt() ->> 'org_id')::uuid);

COMMENT ON VIEW public.coaches_directory IS
  'Org-scoped id/name of ACTIVE coach-role users, for the "assign coach" '
  'dropdown. active = false coaches are excluded so they cannot be assigned '
  'to a new package.';

-- ---------------------------------------------------------------------------
-- pt_packages_validate_refs — the coach must also be active. Same body as
-- 20260829091000 otherwise.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.pt_packages_validate_refs()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_coach_role   TEXT;
  v_coach_org    UUID;
  v_coach_active BOOLEAN;
  v_member_org   UUID;
BEGIN
  SELECT role, organization_id, active
    INTO v_coach_role, v_coach_org, v_coach_active
    FROM public.users WHERE id = NEW.coach_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'pt_packages.coach_id % does not exist in users', NEW.coach_id;
  END IF;
  IF v_coach_role <> 'coach' THEN
    RAISE EXCEPTION 'pt_packages.coach_id % has role %, must be coach', NEW.coach_id, v_coach_role;
  END IF;
  IF NOT v_coach_active THEN
    RAISE EXCEPTION 'pt_packages.coach_id % is deactivated', NEW.coach_id;
  END IF;
  IF v_coach_org <> NEW.organization_id THEN
    RAISE EXCEPTION 'pt_packages.coach_id % belongs to org %, not %',
      NEW.coach_id, v_coach_org, NEW.organization_id;
  END IF;

  SELECT organization_id INTO v_member_org
    FROM public.members WHERE id = NEW.member_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'pt_packages.member_id % does not exist in members', NEW.member_id;
  END IF;
  IF v_member_org <> NEW.organization_id THEN
    RAISE EXCEPTION 'pt_packages.member_id % belongs to org %, not %',
      NEW.member_id, v_member_org, NEW.organization_id;
  END IF;

  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.pt_packages_validate_refs() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.pt_packages_validate_refs() FROM anon, authenticated, service_role;
