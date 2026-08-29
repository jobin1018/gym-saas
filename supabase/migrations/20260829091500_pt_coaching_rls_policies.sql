-- RLS for pt_packages / training_notes / body_measurements, plus the
-- hardening of four existing policies that adding a third role forces.
--
-- ============================================================================
-- SAME PATTERN AS EVERYTHING ELSE — not a new one
-- ============================================================================
-- Every policy here is the established shape from
-- 20260824140500_rewrite_tenant_isolation_policies_for_jwt.sql:
--   organization_id = (auth.jwt() ->> 'org_id')::uuid
--   AND ( <role branch> OR <role branch> ... )
-- read via auth.jwt(), NULL-on-missing-claim => deny, no GUCs. New
-- ingredients: the `user_id` claim (20260829090000), and the cross-table
-- lookups go through the SECURITY DEFINER helpers in 20260829091200 instead
-- of inline EXISTS — see that migration for why (the members <-> pt_packages
-- policy cycle).
--
-- ============================================================================
-- ONE RULE FOR THE COACH, ACROSS ALL FOUR TABLES
-- ============================================================================
--   A coach sees a member — and that member's packages, notes and
--   measurements — IF AND ONLY IF an ACTIVE pt_packages row assigns that
--   member to that coach (coach_id = the caller's user_id claim).
--
-- Consequences, all intended:
--   * not location-scoped: a coach with clients across a multi-location org
--     sees all of them; a coach sees NONE of their home branch's other
--     members. (The members policy previously matched any non-owner whose
--     location_id claim matched the row — a coach has such a claim. Tightened
--     below to name front_desk explicitly.)
--   * when a package flips to 'completed'/'cancelled' the member drops off
--     the coach's view entirely (list, detail, notes, measurements). The
--     OWNER keeps the full history org-wide.
--
-- ============================================================================
-- front_desk — CREATE packages yes, read notes/measurements no
-- ============================================================================
-- front_desk gets pt_packages scoped to their location's members, WITH CHECK
-- included, exactly like tenant_isolation_memberships — they can't attach a
-- package to another branch's member. They get NO access to training_notes /
-- body_measurements: delivery detail, same call as front_desk not seeing
-- payments. Owner reads everything; a front-desk PIN can't.
--
-- ============================================================================
-- WRITES
-- ============================================================================
--   pt_packages       : owner (org) | front_desk (own location). NOT coach.
--   training_notes    : the assigned coach only, for an active package.
--   body_measurements : the assigned coach only, for an active package.
-- Owner read on notes/measurements is org-wide oversight; owner writes go
-- through Studio/psql, not the API. Keeping the write surface to exactly "the
-- assigned coach" is the cleanest thing to state and test.
-- ============================================================================

ALTER TABLE public.pt_packages       ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.training_notes    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.body_measurements ENABLE ROW LEVEL SECURITY;

-- ---------------------------------------------------------------------------
-- pt_packages
-- ---------------------------------------------------------------------------
CREATE POLICY tenant_isolation_pt_packages ON public.pt_packages
  USING (
    organization_id = (auth.jwt() ->> 'org_id')::uuid
    AND (
      (auth.jwt() ->> 'app_role') = 'owner'
      OR (
        (auth.jwt() ->> 'app_role') = 'front_desk'
        AND public.pt_member_at_location(member_id, (auth.jwt() ->> 'location_id')::uuid)
      )
      OR (
        (auth.jwt() ->> 'app_role') = 'coach'
        AND coach_id = (auth.jwt() ->> 'user_id')::uuid
        AND status = 'active'
      )
    )
  )
  WITH CHECK (
    organization_id = (auth.jwt() ->> 'org_id')::uuid
    AND (
      (auth.jwt() ->> 'app_role') = 'owner'
      OR (
        (auth.jwt() ->> 'app_role') = 'front_desk'
        AND public.pt_member_at_location(member_id, (auth.jwt() ->> 'location_id')::uuid)
      )
    )
  );

-- ---------------------------------------------------------------------------
-- training_notes
-- ---------------------------------------------------------------------------
CREATE POLICY tenant_isolation_training_notes ON public.training_notes
  USING (
    organization_id = (auth.jwt() ->> 'org_id')::uuid
    AND (
      (auth.jwt() ->> 'app_role') = 'owner'
      OR (
        (auth.jwt() ->> 'app_role') = 'coach'
        AND coach_id = (auth.jwt() ->> 'user_id')::uuid
        AND public.pt_active_package_match(
              pt_package_id, member_id,
              (auth.jwt() ->> 'user_id')::uuid, (auth.jwt() ->> 'org_id')::uuid)
      )
    )
  )
  WITH CHECK (
    organization_id = (auth.jwt() ->> 'org_id')::uuid
    AND (auth.jwt() ->> 'app_role') = 'coach'
    AND coach_id = (auth.jwt() ->> 'user_id')::uuid
    AND public.pt_active_package_match(
          pt_package_id, member_id,
          (auth.jwt() ->> 'user_id')::uuid, (auth.jwt() ->> 'org_id')::uuid)
  );

-- ---------------------------------------------------------------------------
-- body_measurements — keyed on recorded_by; no pt_package_id column, so the
-- assignment test is member-level.
-- ---------------------------------------------------------------------------
CREATE POLICY tenant_isolation_body_measurements ON public.body_measurements
  USING (
    organization_id = (auth.jwt() ->> 'org_id')::uuid
    AND (
      (auth.jwt() ->> 'app_role') = 'owner'
      OR (
        (auth.jwt() ->> 'app_role') = 'coach'
        AND public.pt_active_assignment_exists(
              member_id, (auth.jwt() ->> 'user_id')::uuid, (auth.jwt() ->> 'org_id')::uuid)
      )
    )
  )
  WITH CHECK (
    organization_id = (auth.jwt() ->> 'org_id')::uuid
    AND (auth.jwt() ->> 'app_role') = 'coach'
    AND recorded_by = (auth.jwt() ->> 'user_id')::uuid
    AND public.pt_active_assignment_exists(
          member_id, (auth.jwt() ->> 'user_id')::uuid, (auth.jwt() ->> 'org_id')::uuid)
  );

-- ===========================================================================
-- HARDENING EXISTING POLICIES FOR THE NEW ROLE
-- ===========================================================================
-- Before this migration, every non-owner branch of these policies was
-- `... OR <location_id match>`, on the tacit assumption non-owner ==
-- front_desk. `coach` is a third role that ALSO carries a location_id claim
-- (home branch), so those bare location matches would now grant a coach read
-- access to their home branch's members / memberships / attendance /
-- whatsapp_messages — exactly the "all members at their location" access the
-- coaching model says a coach must NOT have.
--
-- Fix: name the role — `app_role = 'front_desk'` — on the location branch.
-- owner and front_desk behaviour is byte-identical to before; coach falls
-- through to deny (it gets its own assignment-scoped branch only on members,
-- the one table it actually needs). payments already says `= 'owner'`
-- explicitly and needs no change.
-- ---------------------------------------------------------------------------

-- members — owner (org) | front_desk (own location) | coach (active-assigned)
DROP POLICY tenant_isolation_members ON public.members;
CREATE POLICY tenant_isolation_members ON public.members
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
        AND public.pt_active_assignment_exists(
              id, (auth.jwt() ->> 'user_id')::uuid, (auth.jwt() ->> 'org_id')::uuid)
      )
    )
  )
  WITH CHECK (
    organization_id = (auth.jwt() ->> 'org_id')::uuid
    AND (
      (auth.jwt() ->> 'app_role') = 'owner'
      OR (
        (auth.jwt() ->> 'app_role') = 'front_desk'
        AND location_id = (auth.jwt() ->> 'location_id')::uuid
      )
    )
  );

-- memberships — reached through member_id -> members.location_id
DROP POLICY tenant_isolation_memberships ON public.memberships;
CREATE POLICY tenant_isolation_memberships ON public.memberships
  USING (
    organization_id = (auth.jwt() ->> 'org_id')::uuid
    AND (
      (auth.jwt() ->> 'app_role') = 'owner'
      OR (
        (auth.jwt() ->> 'app_role') = 'front_desk'
        AND EXISTS (
          SELECT 1 FROM public.members m
           WHERE m.id = memberships.member_id
             AND m.location_id = (auth.jwt() ->> 'location_id')::uuid
        )
      )
    )
  )
  WITH CHECK (
    organization_id = (auth.jwt() ->> 'org_id')::uuid
    AND (
      (auth.jwt() ->> 'app_role') = 'owner'
      OR (
        (auth.jwt() ->> 'app_role') = 'front_desk'
        AND EXISTS (
          SELECT 1 FROM public.members m
           WHERE m.id = memberships.member_id
             AND m.location_id = (auth.jwt() ->> 'location_id')::uuid
        )
      )
    )
  );

-- attendance — reached through member_id -> members.location_id
DROP POLICY tenant_isolation_attendance ON public.attendance;
CREATE POLICY tenant_isolation_attendance ON public.attendance
  USING (
    organization_id = (auth.jwt() ->> 'org_id')::uuid
    AND (
      (auth.jwt() ->> 'app_role') = 'owner'
      OR (
        (auth.jwt() ->> 'app_role') = 'front_desk'
        AND EXISTS (
          SELECT 1 FROM public.members m
           WHERE m.id = attendance.member_id
             AND m.location_id = (auth.jwt() ->> 'location_id')::uuid
        )
      )
    )
  );

-- whatsapp_messages — member-tied rows location-scoped; member_id IS NULL
-- broadcasts stay owner-only.
DROP POLICY tenant_isolation_wa_messages ON public.whatsapp_messages;
CREATE POLICY tenant_isolation_wa_messages ON public.whatsapp_messages
  USING (
    organization_id = (auth.jwt() ->> 'org_id')::uuid
    AND (
      (auth.jwt() ->> 'app_role') = 'owner'
      OR (
        (auth.jwt() ->> 'app_role') = 'front_desk'
        AND member_id IS NOT NULL
        AND EXISTS (
          SELECT 1 FROM public.members m
           WHERE m.id = whatsapp_messages.member_id
             AND m.location_id = (auth.jwt() ->> 'location_id')::uuid
        )
      )
    )
  );
