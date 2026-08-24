-- staff_lookup_directory — a safe, narrow view for resolving which org(s) a
-- phone number belongs to, BEFORE a PIN is ever entered.
--
-- ============================================================================
-- WHY A VIEW, NOT A DIRECT QUERY ON users
-- ============================================================================
-- staff-lookup-by-phone (supabase/functions/staff-lookup-by-phone/index.ts)
-- runs pre-login — the frontend has a phone number and nothing else, so it
-- has to query across ALL organizations to find out which one(s) that phone
-- belongs to. That is exactly the shape of query users.pin_hash must NEVER
-- be anywhere near the response of. Rather than trust every future caller of
-- this table to remember to exclude one column, this view hard-codes the
-- exclusion at the schema level — same column-masking discipline as
-- organizations_for_client (20260824141000_revoke_local_dev_only_policies.sql).
--
-- organization_name is joined in here (not left to the caller to fetch
-- separately) because the whole point of this lookup is letting the frontend
-- show "Priya Nair — Iron Temple Gym" or a disambiguation list without a
-- second round trip.
--
-- security_invoker = true for consistency with organizations_for_client, even
-- though in practice only service_role (which bypasses RLS regardless of
-- invoker/definer) is ever granted SELECT on this view — see the companion
-- grants migration.
-- ============================================================================
CREATE VIEW public.staff_lookup_directory
WITH (security_invoker = true) AS
SELECT
  u.id,
  u.organization_id,
  o.name AS organization_name,
  u.phone,
  u.name,
  u.role
FROM public.users u
JOIN public.organizations o ON o.id = u.organization_id;

COMMENT ON VIEW public.staff_lookup_directory IS
  'Cross-organization phone -> staff lookup for staff-lookup-by-phone. '
  'Deliberately excludes pin_hash, location_id and everything else on users '
  'not needed to resolve/display a match. service_role only — never exposed '
  'to anon/authenticated via PostgREST directly, only read internally by the '
  'Edge Function.';
