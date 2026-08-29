-- Extend the coach's READ history to inactive packages across members,
-- training_notes and body_measurements — mirroring what 20260829093000 did
-- for pt_packages. Writes are untouched: still active-assignment only.
--
-- ============================================================================
-- WHY
-- ============================================================================
-- 20260829093000 let a coach keep SELECT on their completed/cancelled
-- pt_packages as delivery history. But the members / training_notes /
-- body_measurements coach branches still went through the `_active_` helpers,
-- so the moment a package completed the coach lost the client's name, every
-- session note and every weigh-in for it — you could see that a package
-- existed and nothing inside it. The paginated session-history view
-- (log_session's companion read) needs that history to be readable.
--
-- This migration finishes the 093000 decision across the whole coach READ
-- surface:
--   * a coach may SELECT a member, their training_notes and their
--     body_measurements if ANY package (any status) assigns that member to
--     that coach;
--   * a coach may still only INSERT a note/measurement while the package is
--     'active' — every WITH CHECK clause is left exactly as 20260829091500
--     wrote it (owner + assigned-coach-with-active-package; front_desk for
--     pt_packages only).
--
-- Same shape as every policy here: org match via auth.jwt() ->> 'org_id',
-- role via app_role, coach identity via the user_id claim, cross-table
-- lookups via SECURITY DEFINER helpers (the members <-> pt_packages policy
-- cycle, see 20260829091200). Only the USING expression of each policy is
-- replaced (ALTER POLICY ... USING), so WITH CHECK stays put.
--
-- ============================================================================
-- CONSEQUENCE, INTENDED
-- ============================================================================
-- A coach accumulates a permanent, read-only roster of everyone they have
-- ever trained (name/phone, notes, measurements) for that org. That is the
-- point — it is their coaching record. The owner already sees all of it
-- org-wide; front_desk sees none of the notes/measurements either way.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Any-status counterparts of the 20260829091200 helpers. Identical bodies
-- minus the `AND p.status = 'active'` line. Kept as separate functions rather
-- than parameterising the originals so the WITH CHECK clauses that still call
-- the `_active_` versions need no churn.
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.pt_assignment_exists(p_member uuid, p_coach uuid, p_org uuid)
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public, pg_temp
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.pt_packages p
     WHERE p.member_id = p_member
       AND p.coach_id  = p_coach
       AND p.organization_id = p_org
  );
$$;

CREATE FUNCTION public.pt_package_match(
  p_package uuid, p_member uuid, p_coach uuid, p_org uuid)
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public, pg_temp
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.pt_packages p
     WHERE p.id = p_package
       AND p.member_id = p_member
       AND p.coach_id  = p_coach
       AND p.organization_id = p_org
  );
$$;

REVOKE ALL ON FUNCTION public.pt_assignment_exists(uuid, uuid, uuid)        FROM PUBLIC;
REVOKE ALL ON FUNCTION public.pt_package_match(uuid, uuid, uuid, uuid)      FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.pt_assignment_exists(uuid, uuid, uuid)     TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.pt_package_match(uuid, uuid, uuid, uuid)   TO anon, authenticated;

-- ---------------------------------------------------------------------------
-- members — coach branch: active-assigned -> any-assigned (READ only).
-- owner / front_desk branches and the whole WITH CHECK are unchanged.
-- ---------------------------------------------------------------------------
ALTER POLICY tenant_isolation_members ON public.members
  USING (
    organization_id = (auth.jwt() ->> 'org_id')::uuid
    AND (
      (auth.jwt() ->> 'app_role') = 'owner'
      OR (
        (auth.jwt() ->> 'app_role') = 'front_desk'
        AND location_id = (auth.jwt() ->> 'location_id')::uuid
      )
      OR (
        (auth.jwt() ->> 'app_role') = 'coach'
        AND public.pt_assignment_exists(
              id, (auth.jwt() ->> 'user_id')::uuid, (auth.jwt() ->> 'org_id')::uuid)
      )
    )
  );

-- ---------------------------------------------------------------------------
-- training_notes — coach USING branch: active-package-match -> any-status
-- match. WITH CHECK still requires pt_active_package_match (active only).
-- ---------------------------------------------------------------------------
ALTER POLICY tenant_isolation_training_notes ON public.training_notes
  USING (
    organization_id = (auth.jwt() ->> 'org_id')::uuid
    AND (
      (auth.jwt() ->> 'app_role') = 'owner'
      OR (
        (auth.jwt() ->> 'app_role') = 'coach'
        AND coach_id = (auth.jwt() ->> 'user_id')::uuid
        AND public.pt_package_match(
              pt_package_id, member_id,
              (auth.jwt() ->> 'user_id')::uuid, (auth.jwt() ->> 'org_id')::uuid)
      )
    )
  );

-- ---------------------------------------------------------------------------
-- body_measurements — coach USING branch: active-assignment -> any-status
-- assignment. WITH CHECK still requires pt_active_assignment_exists.
-- ---------------------------------------------------------------------------
ALTER POLICY tenant_isolation_body_measurements ON public.body_measurements
  USING (
    organization_id = (auth.jwt() ->> 'org_id')::uuid
    AND (
      (auth.jwt() ->> 'app_role') = 'owner'
      OR (
        (auth.jwt() ->> 'app_role') = 'coach'
        AND public.pt_assignment_exists(
              member_id, (auth.jwt() ->> 'user_id')::uuid, (auth.jwt() ->> 'org_id')::uuid)
      )
    )
  );
