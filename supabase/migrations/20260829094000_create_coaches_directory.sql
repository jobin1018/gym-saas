-- coaches_directory — a safe, narrow view letting owner/front_desk populate
-- an "assign coach" dropdown, without ever granting direct SELECT on users.
--
-- ============================================================================
-- WHY THIS CANNOT FOLLOW organizations_for_client's security_invoker=true
-- PATTERN
-- ============================================================================
-- organizations_for_client works with security_invoker=true because
-- `organizations` already GRANTs SELECT to anon/authenticated — RLS narrows
-- rows, the view only needs to mask two columns. `users` grants NEITHER anon
-- NOR authenticated any SELECT at all (deliberate — see every prior users-
-- adjacent migration; it holds pin_hash). A security_invoker view over users
-- would re-check the CALLER's privileges on the base table and fail closed
-- for every authenticated session, which is not what we want here — the
-- coach dropdown genuinely needs owner/front_desk to read a filtered slice
-- of `users` they have no direct grant on.
--
-- staff_lookup_directory faces the identical base-table problem and also
-- uses security_invoker=true "for consistency", but that is safe ONLY
-- because its sole caller is service_role (bypasses RLS and grants alike,
-- invoker or not) via the staff-lookup-by-phone Edge Function — never called
-- directly by an authenticated session. This view is the opposite: it is
-- meant to be queried directly via supabase-js with the caller's own
-- owner/front_desk session, so that shortcut is not available here.
--
-- ============================================================================
-- THE ACTUAL DESIGN: DEFINER-RIGHTS VIEW, FILTER BAKED INTO THE QUERY
-- ============================================================================
-- Omitting security_invoker (Postgres's default) makes this view run with
-- ITS OWNER's privileges on `users` — full read access to the base table,
-- same as any other definer-rights view — while the SELECT itself does the
-- narrowing that would otherwise come from RLS: org match via auth.jwt(),
-- and role = 'coach'. auth.jwt() reads the request's JWT claims from a
-- session GUC regardless of definer/invoker context (the same mechanism
-- custom_access_token_hook and every RLS policy already rely on), so this
-- still scopes correctly per caller despite running with elevated rights.
--
-- Only id and name are exposed — no phone, no location_id, no pin_hash,
-- nothing else on users. `authenticated` gets SELECT on the VIEW only (see
-- the companion grants migration); `users` itself remains exactly as
-- ungrantable as it was before this file.
-- ============================================================================
CREATE VIEW public.coaches_directory AS
SELECT id, name
FROM public.users
WHERE role = 'coach'
  AND organization_id = (auth.jwt() ->> 'org_id')::uuid;

COMMENT ON VIEW public.coaches_directory IS
  'Org-scoped id/name of coach-role users, for the owner/front_desk '
  '"assign coach" dropdown on Members. Deliberately NOT security_invoker: '
  'users grants no SELECT to anon/authenticated at all, so this view runs '
  'with definer rights and does its own org_id/role filtering via auth.jwt() '
  'instead. Exposes only id and name — never phone, location_id or pin_hash.';
