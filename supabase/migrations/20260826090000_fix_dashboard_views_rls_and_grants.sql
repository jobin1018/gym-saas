-- Fix v_daily_revenue / v_lapsed_members: missing grants, AND missing
-- security_invoker — found while diagnosing the Revenue page showing ₹0.
--
-- ============================================================================
-- WHY THE REVENUE PAGE SHOWED ZERO — AND WHY THE OBVIOUS FIX WAS WRONG
-- ============================================================================
-- Both views were created in the original schema migration
-- (20260822041613_create_core_schema.sql), before real auth or RLS existed.
-- Neither ever got a GRANT SELECT for `authenticated` — confirmed via
-- information_schema.role_table_grants, which showed only the meaningless
-- default TRUNCATE/REFERENCES/TRIGGER privileges every table gets. That is
-- the direct cause of "0 collected": a logged-in owner session hits
-- 42501 permission denied querying either view, which the frontend
-- apparently renders as "no data" rather than surfacing the error.
--
-- The obvious fix — just GRANT SELECT — would have been actively dangerous.
-- Both are PLAIN views (confirmed via pg_class.reloptions: no
-- security_invoker, owned by `postgres`), which means they run with the
-- VIEW OWNER's privileges, not the querying session's. `postgres` bypasses
-- RLS entirely (superuser), so a bare GRANT would let ANY authenticated
-- session — front_desk included — see every organization's revenue and every
-- organization's lapsed members, completely ignoring payments' owner-only
-- RLS policy and members'/attendance's location scoping. That is a real
-- cross-tenant AND cross-role data leak, worse than the bug being fixed.
--
-- organizations_for_client (20260824141000_revoke_local_dev_only_policies.sql)
-- already got this right with `WITH (security_invoker = true)` at creation
-- time; these two views predate that pattern and were missed when the RLS
-- rewrite touched every table but not the two pre-existing views sitting on
-- top of them. This migration is that fix, applied without needing to
-- DROP/CREATE either view — Postgres 15+ supports altering the option on an
-- existing view directly.
-- ============================================================================

ALTER VIEW public.v_daily_revenue  SET (security_invoker = true);
ALTER VIEW public.v_lapsed_members SET (security_invoker = true);

-- anon gets SELECT too, same reasoning as every table grant in
-- 20260824141000_revoke_local_dev_only_policies.sql: RLS (now correctly
-- enforced via security_invoker above) is what should produce a clean empty
-- result for an unauthenticated caller, not a 42501 permission error at the
-- grant boundary.
GRANT SELECT ON public.v_daily_revenue  TO anon, authenticated;
GRANT SELECT ON public.v_lapsed_members TO anon, authenticated;

COMMENT ON VIEW public.v_daily_revenue IS
  'Daily successful-payment totals per organization. security_invoker=true so '
  'it enforces payments'' own owner-only tenant_isolation_payments RLS policy '
  'as the querying session — front_desk sessions correctly see zero rows here, '
  'same as querying payments directly.';

COMMENT ON VIEW public.v_lapsed_members IS
  'Members with no check-in in 14+ days, per organization. '
  'security_invoker=true so it enforces members''/attendance''s own '
  'location-scoped RLS as the querying session — front_desk sessions see only '
  'their own location''s lapsed members, owner sees the whole org.';
