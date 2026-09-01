-- Grants for the staff-manage Edge Function.
--
-- ============================================================================
-- COLUMN-SCOPED, SAME DISCIPLINE AS staff-login / staff-pin-reset
-- ============================================================================
-- 20260824130500 established that service_role's write access to public.users
-- is granted one column at a time, on purpose: "withholding those columns is
-- what keeps 'this function cannot change who someone is' enforced by the
-- database rather than by convention." staff-manage follows the same rule.
--
--   create      -> INSERT of exactly the columns it sets. id / created_at /
--                  auth_user_id are omitted from the INSERT and take their
--                  column defaults, so they need no grant.
--   deactivate  -> UPDATE (active) only.
--   reactivate  -> UPDATE (active) only.
--
-- So staff-manage can add a staffer and flip their active flag, and can do
-- NOTHING else to the users table — it cannot touch pin_hash on an existing
-- row (that is staff-pin-reset's single column), cannot move someone between
-- orgs, cannot change a role after creation.
--
-- It also SELECTs public.locations (to check a new front_desk/coach's branch
-- belongs to the caller's org) and calls auth.admin.signOut on deactivate —
-- service_role already has SELECT on locations (20260822041613 era) and the
-- GoTrue Admin API needs no table grant.
-- ============================================================================

GRANT INSERT (organization_id, name, phone, role, location_id, pin_hash, active)
  ON public.users TO service_role;

GRANT UPDATE (active) ON public.users TO service_role;
