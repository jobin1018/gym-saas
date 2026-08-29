-- Widen the coach SELECT branch of tenant_isolation_pt_packages to include
-- completed/cancelled packages — read-only history, writes stay active-only.
--
-- ============================================================================
-- WHAT CHANGES, AND WHAT DOES NOT
-- ============================================================================
-- 20260829091500 gave a coach SELECT on pt_packages only while
-- `status = 'active'`, so a finished engagement vanished from the coach's
-- view entirely. This ALTER drops the `AND status = 'active'` from the coach
-- branch of the USING clause ONLY, so a coach keeps read access to every
-- package they were assigned — active, completed or cancelled — as their own
-- delivery history.
--
-- Everything else is deliberately untouched:
--   * WITH CHECK is not restated, so it stays exactly as 20260829091500 left
--     it — owner + location-scoped front_desk, NO coach branch. A coach still
--     cannot INSERT or UPDATE a pt_packages row of any status.
--   * training_notes / body_measurements policies are unchanged: their coach
--     branches go through pt_active_package_match() / pt_active_assignment_
--     exists(), both of which still require `status = 'active'`. So once a
--     package is completed/cancelled the coach can read it but can log
--     nothing further against it or that member.
--   * the members policy's coach branch still uses pt_active_assignment_
--     exists() (active only) — a completed-package member does not reappear in
--     the coach's member list; the history lives on the pt_packages row.
--   * owner (org-wide) and front_desk (own location) branches unchanged.
--
-- ============================================================================
-- WHY ALTER POLICY, NOT DROP/CREATE
-- ============================================================================
-- ALTER POLICY ... USING (...) replaces just the USING expression and leaves
-- WITH CHECK as-is — the smallest possible change, and it keeps the full
-- policy definition (and the reasoning for every other branch) in
-- 20260829091500 as the single source of truth rather than forking a second
-- copy here. Same tenant + role scoping discipline: org match via
-- auth.jwt() ->> 'org_id', role via app_role, coach identity via the user_id
-- claim, cross-table lookups via the SECURITY DEFINER helpers.
-- ============================================================================

ALTER POLICY tenant_isolation_pt_packages ON public.pt_packages
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
      )
    )
  );
