-- Grants for pt_packages / training_notes / body_measurements.
--
-- ============================================================================
-- WHY DIRECT `authenticated` WRITES, AND NO EDGE FUNCTION
-- ============================================================================
-- The early functions (staff-login, the webhooks, renewal-scan) run on
-- service_role for reasons that DO NOT apply here:
--   * staff-login / staff-lookup: pre-login, need the Admin API + a
--     cross-org read of a table (users.pin_hash) that must never be exposed.
--   * razorpay-webhook / send-renewal-reminder / renewal-scan / mark-overdue:
--     spend real money, call external APIs, or run as pg_cron with no user.
--   * everything predating 20260824140500: RLS wasn't reading a JWT yet, so
--     service_role was the ONLY way to get tenant scoping at all.
--
-- Creating a pt_package (owner/front_desk) and logging a note/measurement
-- (coach) are none of that: a single-row INSERT into one table, post-login,
-- no external call, no secret, no money. RLS now expresses exactly who may do
-- each (20260829091500) and the pt_packages trigger (20260829091000) enforces
-- the cross-row integrity a WITH CHECK can't. This is precisely the case the
-- JWT-RLS rewrite was built for — the same reason `members` and `memberships`
-- became direct `authenticated` writes in
-- 20260824141000_revoke_local_dev_only_policies.sql. An Edge Function here
-- would add a network hop, a service_role key surface, and a second copy of
-- the authorization logic, buying nothing.
--
-- ============================================================================
-- anon GETS SELECT TOO — same reason as every other table
-- ============================================================================
-- With no grant at all, PostgREST answers a read with 42501 "permission
-- denied for table" (HTTP 401) BEFORE RLS runs. The anon key's JWT carries no
-- org_id/app_role/user_id, so tenant_isolation_* denies it to zero rows on
-- its own — the SELECT grant just lets the request reach RLS and get a clean
-- `[]`. anon still gets NO INSERT anywhere.
--
-- ============================================================================
-- APPEND-ONLY: no UPDATE/DELETE on training_notes / body_measurements
-- ============================================================================
-- A logged session note and a weigh-in are historical facts. The UI's
-- "replace same-date measurement" behaviour becomes "the latest row by
-- recorded_at wins" against a real backend — no in-place edit needed. Not
-- granting UPDATE/DELETE keeps that a schema guarantee. pt_packages DOES get
-- UPDATE (owner/front_desk, via RLS) — session counts and status legitimately
-- change over a package's life.
--
-- ============================================================================
-- NO service_role GRANTS
-- ============================================================================
-- Nothing server-side touches these tables yet — no webhook, no cron, no
-- function. When PT billing arrives (see the deferred-payment note in
-- 20260829091000) whatever function reconciles a PT payment will add its own
-- minimal grant here, scoped to what it does, same as every other grants
-- migration in this project.
-- ============================================================================

GRANT SELECT               ON public.pt_packages       TO anon, authenticated;
GRANT INSERT, UPDATE       ON public.pt_packages       TO authenticated;

GRANT SELECT               ON public.training_notes    TO anon, authenticated;
GRANT INSERT               ON public.training_notes    TO authenticated;

GRANT SELECT               ON public.body_measurements TO anon, authenticated;
GRANT INSERT               ON public.body_measurements TO authenticated;
