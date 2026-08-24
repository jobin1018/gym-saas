-- Reverse the three LOCAL_DEV_ONLY migrations for good, and grant the real,
-- deliberate access `authenticated` needs now that RLS actually reads a JWT.
--
-- ============================================================================
-- WHY A NEW MIGRATION, NOT EDITS TO THE OLD THREE
-- ============================================================================
-- 20260823160000_LOCAL_DEV_ONLY_permissive_read_policies.sql,
-- 20260823170000_LOCAL_DEV_ONLY_permissive_write_policies.sql, and
-- 20260824120000_LOCAL_DEV_ONLY_permissive_update_policies.sql are NOT
-- deleted or edited — this is a pure subtraction layered on top, so the
-- history of what was opened and why stays intact. Each of those three files
-- already carries its own ROLLBACK comment block; this migration does
-- exactly what those three blocks say, mechanically, plus the real grants
-- that now replace the dev-permissive ones.
--
--   select * from pg_policies
--    where schemaname = 'public' and policyname like 'local_dev_%';
--   -- MUST return zero rows after this migration, on any database.
-- ============================================================================

-- --- from 20260823160000 (read) ---
DROP POLICY IF EXISTS local_dev_read_organizations     ON public.organizations;
DROP POLICY IF EXISTS local_dev_read_locations         ON public.locations;
DROP POLICY IF EXISTS local_dev_read_members           ON public.members;
DROP POLICY IF EXISTS local_dev_read_membership_plans  ON public.membership_plans;
DROP POLICY IF EXISTS local_dev_read_memberships       ON public.memberships;
DROP POLICY IF EXISTS local_dev_read_payments          ON public.payments;
DROP POLICY IF EXISTS local_dev_read_attendance        ON public.attendance;
DROP POLICY IF EXISTS local_dev_read_whatsapp_messages ON public.whatsapp_messages;

REVOKE SELECT ON public.organizations     FROM anon, authenticated;
REVOKE SELECT ON public.locations         FROM anon, authenticated;
REVOKE SELECT ON public.members           FROM anon, authenticated;
REVOKE SELECT ON public.membership_plans  FROM anon, authenticated;
REVOKE SELECT ON public.memberships       FROM anon, authenticated;
REVOKE SELECT ON public.payments          FROM anon, authenticated;
REVOKE SELECT ON public.attendance        FROM anon, authenticated;
REVOKE SELECT ON public.whatsapp_messages FROM anon, authenticated;

-- --- from 20260823170000 (insert) ---
DROP POLICY IF EXISTS local_dev_insert_members     ON public.members;
DROP POLICY IF EXISTS local_dev_insert_memberships ON public.memberships;
REVOKE INSERT ON public.members     FROM anon, authenticated;
REVOKE INSERT ON public.memberships FROM anon, authenticated;

-- --- from 20260824120000 (update) ---
DROP POLICY IF EXISTS local_dev_update_members     ON public.members;
DROP POLICY IF EXISTS local_dev_update_memberships ON public.memberships;
REVOKE UPDATE ON public.members     FROM anon, authenticated;
REVOKE UPDATE ON public.memberships FROM anon, authenticated;

-- ============================================================================
-- THE REAL GRANTS — anon gets SELECT too, on purpose, so RLS is what returns
-- zero rows, not the grant boundary
-- ============================================================================
-- GRANT is per Postgres ROLE (anon / authenticated / service_role) — it has
-- zero visibility into app_role (owner vs front_desk), which lives only as a
-- JWT claim the policies in 20260824140500_rewrite_tenant_isolation_policies_
-- for_jwt.sql read. So the base grant to `authenticated` has to be the UNION
-- of what owner + front_desk can EVER see; RLS narrows per-request from
-- there. GRANT and RLS are AND'd, not alternatives: an owner session still
-- needs the payments GRANT below to read anything at all, even though RLS is
-- what excludes front_desk from it.
--
-- anon ALSO gets SELECT here — found the hard way, not assumed: with NO grant
-- at all, PostgREST answers a read attempt with 42501 "permission denied for
-- table ..." (HTTP 401) BEFORE RLS is even consulted, which is a real ERROR,
-- not the clean "zero rows" response an unauthenticated request should get.
-- The anon key's JWT carries no org_id/app_role claim (the hook only ever
-- fires for a real staff-login session), so tenant_isolation_* denies it down
-- to zero rows on its own — the SELECT grant just lets the request reach RLS
-- at all instead of being rejected one layer earlier. anon still gets NO
-- INSERT/UPDATE anywhere: a write attempt failing loudly is fine and
-- unexercised by any requirement here, unlike reads.
-- ============================================================================
GRANT SELECT ON public.organizations      TO anon, authenticated;
GRANT SELECT ON public.locations          TO anon, authenticated;
GRANT SELECT ON public.members            TO anon, authenticated;
GRANT INSERT, UPDATE ON public.members    TO authenticated;
GRANT SELECT ON public.membership_plans   TO anon, authenticated;
GRANT SELECT ON public.memberships        TO anon, authenticated;
GRANT INSERT, UPDATE ON public.memberships TO authenticated;
GRANT SELECT ON public.payments           TO anon, authenticated;
GRANT SELECT ON public.attendance         TO anon, authenticated;
GRANT SELECT ON public.whatsapp_messages  TO anon, authenticated;
-- public.users: NO grant added — see the role-restriction note in
-- 20260824140500_rewrite_tenant_isolation_policies_for_jwt.sql. staff-login's
-- own response already covers "who am I" (name/role/org/location); a
-- coworker-roster read is future scope, deliberately deferred, not an
-- oversight.
-- public.login_attempts, public.webhook_events: unchanged, service_role only.

-- ============================================================================
-- organizations_for_client — column-masking view for gst_number/owner_phone
-- ============================================================================
-- RLS is ROW-level only; there is no policy-based way to hide one column
-- (gst_number, owner_phone) from front_desk while still returning the rest of
-- an organizations row it plausibly needs (name for branding, status to know
-- if the org is suspended). A masking VIEW is the standard fix.
-- security_invoker = true (Postgres 17) is NOT optional here — without it the
-- view runs as ITS OWNER and bypasses organizations' own RLS entirely,
-- silently undoing the org-scoping this whole migration exists to add. The
-- base table's GRANT SELECT above stays in place on purpose: the view still
-- needs it, since with security_invoker=true it re-checks organizations' RLS
-- as the querying session, not as the view's owner.
CREATE VIEW public.organizations_for_client
WITH (security_invoker = true) AS
SELECT
  id,
  name,
  status,
  created_at,
  CASE WHEN (auth.jwt() ->> 'app_role') = 'owner' THEN owner_phone ELSE NULL END AS owner_phone,
  CASE WHEN (auth.jwt() ->> 'app_role') = 'owner' THEN gst_number  ELSE NULL END AS gst_number
FROM public.organizations;

COMMENT ON VIEW public.organizations_for_client IS
  'organizations, with owner_phone/gst_number masked to NULL for any session '
  'whose app_role claim is not ''owner''. security_invoker=true so it still '
  'enforces organizations'' own tenant_isolation_orgs RLS policy as the '
  'querying session. Frontend reads should use this view, not the base table.';

GRANT SELECT ON public.organizations_for_client TO anon, authenticated;
