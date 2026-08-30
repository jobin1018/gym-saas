-- v_members_pt_status — every members column plus "does this member have an
-- active PT package", for list views, without an N+1 lookup.
--
-- ============================================================================
-- WHY A VIEW
-- ============================================================================
-- A member list wants a "PT" badge per row. Doing that per row
-- (member_has_active_pt(id) called once per member) is the N+1 the ask says
-- to avoid. This view answers it for the whole list in one query: two
-- correlated subqueries on pt_packages, both served by
-- idx_pt_packages_member (organization_id, member_id, status).
--
-- has_active_pt is the boolean for the badge; active_pt_count is there for a
-- "2 PT" style count without a second view.
--
-- ============================================================================
-- security_invoker = true — the view carries members' AND pt_packages' RLS
-- ============================================================================
-- Same reasoning as v_daily_revenue (20260826090000): the view must scope to
-- the querying session, not run as its owner. With security_invoker the outer
-- SELECT re-checks tenant_isolation_members (owner: whole org; front_desk:
-- own location; coach: actively-assigned) and each subquery re-checks
-- tenant_isolation_pt_packages as that same session — so has_active_pt can
-- only ever be true for a package the caller is itself allowed to see, which
-- for every role is a package for a member the outer query already returned.
-- `authenticated` already holds SELECT on both members and pt_packages, so
-- the subqueries resolve; anon gets the grant too, for the usual
-- "reach RLS, not the grant wall" reason, and sees nothing (no claims).
--
-- Columns are listed explicitly (not members.*) so the contract is stable and
-- PostgREST can still follow memberships.member_id -> id for an embed if the
-- frontend queries this view instead of the base table.
--
-- NOTE: the zero-migration alternative, for a list that is already loading
-- members, is one bulk sibling query:
--   GET /rest/v1/pt_packages?status=eq.active&select=member_id
-- build a Set from it, flag rows. RLS scopes that result identically. This
-- view is the single-source option; either is fine.
-- ============================================================================

CREATE VIEW public.v_members_pt_status
WITH (security_invoker = true) AS
SELECT
  m.id,
  m.organization_id,
  m.location_id,
  m.name,
  m.phone,
  m.whatsapp_opt_in,
  m.source,
  m.created_at,
  EXISTS (
    SELECT 1 FROM public.pt_packages p
     WHERE p.member_id = m.id AND p.status = 'active'
  ) AS has_active_pt,
  (
    SELECT count(*) FROM public.pt_packages p
     WHERE p.member_id = m.id AND p.status = 'active'
  )::int AS active_pt_count
FROM public.members m;

COMMENT ON VIEW public.v_members_pt_status IS
  'members + has_active_pt / active_pt_count, for list views. '
  'security_invoker=true -> carries members'' and pt_packages'' RLS as the '
  'querying session.';

GRANT SELECT ON public.v_members_pt_status TO anon, authenticated;
