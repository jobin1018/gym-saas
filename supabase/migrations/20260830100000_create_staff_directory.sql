-- staff_directory — an owner-only, org-scoped listing of their own staff
-- (id, name, role, phone), for the new Staff/PIN-reset admin page.
--
-- ============================================================================
-- WHY THIS IS NEEDED
-- ============================================================================
-- public.users has NO SELECT grant for `authenticated` at all (verified:
-- information_schema.role_table_grants). staff_lookup_directory exists but is
-- service_role-only (used by the pre-login staff-lookup-by-phone /
-- staff-login edge functions, not queryable from a logged-in browser
-- session). coaches_directory (20260829094000) exists but is scoped to
-- role='coach' and exposes only id/name — not a general staff list with role
-- and phone. There is no existing view an owner's browser session can query
-- to render "list my staff, reset a PIN". This view fills that gap.
--
-- ============================================================================
-- SAME SHAPE AS coaches_directory — NOT security_invoker, self-scoped in the
-- WHERE clause
-- ============================================================================
-- Since `users` grants no SELECT to authenticated, this view must run with
-- the creating role's privileges to read the underlying table at all — hence
-- no `security_invoker=true`. To avoid that becoming "any authenticated user
-- can read any org's staff", the WHERE clause does the scoping itself, reading
-- straight from the caller's own JWT (auth.jwt() is per-request regardless of
-- definer/invoker rights):
--   * organization_id = the caller's own org — no cross-tenant leakage.
--   * app_role = 'owner' — a front_desk or coach caller gets zero rows, not
--     an error. The frontend route is ALSO guarded (RequireOwner), so this is
--     defense in depth, not the only gate — same posture as
--     v_pt_packages_attention (20260829091*), which uses this identical
--     pattern for the same reason (pt_packages/members/users also don't
--     grant SELECT broadly enough for a plain security_invoker view here).
--
-- pin_hash is deliberately NOT selected — this view is for display only; the
-- actual reset goes through staff-pin-reset (service-role, bcrypt server-
-- side), which reads/writes pin_hash directly and never through this view.
-- ============================================================================

CREATE VIEW public.staff_directory AS
SELECT id, name, role, phone
FROM public.users
WHERE organization_id = ((auth.jwt() ->> 'org_id')::uuid)
  AND (auth.jwt() ->> 'app_role') = 'owner';

GRANT SELECT ON public.staff_directory TO authenticated;
