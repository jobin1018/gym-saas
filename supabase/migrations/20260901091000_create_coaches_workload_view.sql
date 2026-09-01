-- coaches_workload — how busy each (active) coach already is, for the
-- owner/front-desk "assign a coach" decision.
--
-- ============================================================================
-- SAME MASKING-VIEW PATTERN AS coaches_directory — and why NOT security_invoker
-- ============================================================================
-- The task asked for security_invoker=true "same as coaches_directory /
-- staff_directory". Those two are actually NOT security_invoker: `authenticated`
-- has NO SELECT grant on public.users at all (deliberate — it holds pin_hash),
-- so a security_invoker view over users fails closed for every browser session.
-- coaches_directory / staff_directory are therefore DEFINER-rights views
-- (owned by postgres, full read on the base tables) that do their own
-- org-scoping in the WHERE via auth.jwt(). coaches_workload follows that exact
-- pattern:
--   * definer rights (no security_invoker) so it can read users /
--     pt_packages / training_notes;
--   * WHERE organization_id = auth.jwt() ->> 'org_id' — self-scoped per
--     caller, cross-tenant impossible;
--   * role = 'coach' AND active — only assignable coaches appear, matching
--     coaches_directory after 20260901090000.
--
-- ============================================================================
-- WHO CAN READ IT
-- ============================================================================
-- GRANT SELECT TO authenticated, same breadth as coaches_directory: front_desk
-- needs it (they assign coaches), owner needs it, and there is nothing
-- sensitive in "name + a client count + a date" to withhold from a coach
-- session either. NOT anon — no pre-login use.
--
-- The two aggregates are scalar sub-selects rather than GROUP BY joins so a
-- coach with zero active packages / zero notes still shows up (as 0 / NULL),
-- which is exactly the coach an owner most wants to see when assigning.
-- ============================================================================

CREATE VIEW public.coaches_workload AS
SELECT
  u.id,
  u.name,
  (
    SELECT count(*)
    FROM public.pt_packages p
    WHERE p.coach_id = u.id
      AND p.status = 'active'
  )::integer AS active_client_count,
  (
    SELECT max(tn.session_date)
    FROM public.training_notes tn
    WHERE tn.coach_id = u.id
  ) AS most_recent_session_date
FROM public.users u
WHERE u.role = 'coach'
  AND u.active
  AND u.organization_id = ((auth.jwt() ->> 'org_id')::uuid);

COMMENT ON VIEW public.coaches_workload IS
  'Per active coach in the caller''s org: active_client_count (pt_packages '
  'status=active) and most_recent_session_date (max training_notes.session_date). '
  'For the owner/front-desk assign-a-coach decision. Definer-rights + auth.jwt() '
  'org scoping, same pattern as coaches_directory (users has no authenticated '
  'SELECT, so security_invoker cannot be used here). Completed/cancelled '
  'packages are excluded from the count by status=active.';

GRANT SELECT ON public.coaches_workload TO authenticated;
