-- ###########################################################################
-- #                                                                         #
-- #   ██  LOCAL DEV ONLY — MUST BE REPLACED BEFORE STAGING  ██              #
-- #                                                                         #
-- #   THIS MIGRATION DISABLES MULTI-TENANT ISOLATION FOR READS.             #
-- #                                                                         #
-- #   Any caller holding the ANON key — which is public in every client      #
-- #   app that ships — can read EVERY organization's members, payments,      #
-- #   attendance and WhatsApp message history. Every tenant can read every   #
-- #   other tenant's data. On a real deployment this is a total customer     #
-- #   data breach, not a misconfiguration.                                   #
-- #                                                                         #
-- #   It exists for exactly one reason: to let the frontend talk to the      #
-- #   database on localhost before the PIN-auth -> JWT -> RLS chain is       #
-- #   built. Nothing in here is a step toward that chain. It is scaffolding  #
-- #   to be torn out, not a foundation to build on.                          #
-- #                                                                         #
-- #   BEFORE ANY DEPLOYMENT TO STAGING OR PRODUCTION:                        #
-- #     1. Apply the rollback at the bottom of this file, AND                #
-- #     2. Delete this migration file, AND                                   #
-- #     3. Verify with:                                                      #
-- #          select * from pg_policies                                       #
-- #           where schemaname = 'public'                                    #
-- #             and policyname like 'local_dev_%';                           #
-- #        That query MUST return zero rows on any non-local database.       #
-- #                                                                         #
-- ###########################################################################
--
-- ===========================================================================
-- WHY TWO CHANGES ARE NEEDED, NOT ONE
-- ===========================================================================
-- Reads by `anon` were blocked by two independent things, and removing either
-- alone changes nothing:
--
--   1. NO TABLE PRIVILEGE. The five grants migrations granted only to
--      `service_role`. `anon` holds TRIGGER/TRUNCATE/REFERENCES (Supabase's
--      default grant set) but not SELECT, so every query failed with
--      `42501 permission denied for table ...` before RLS was even consulted.
--
--   2. AN RLS POLICY THAT RAISES. The tenant_isolation_* policies read
--      `current_setting('app.current_org_id')::uuid`, and current_setting() on
--      an unset key RAISES rather than returning NULL. So a request with no org
--      context did not come back empty — it came back
--      `42704 unrecognized configuration parameter "app.current_org_id"`.
--
-- The permissive policies below are added ALONGSIDE the tenant_isolation ones
-- rather than replacing them. Postgres OR's permissive policies together, and
-- `true OR <expr>` constant-folds to `true` at plan time, so the raising
-- expression is never evaluated for these roles. That means production policy
-- definitions are left completely untouched by this file — the rollback is a
-- pure subtraction, with nothing to restore.
--
-- ===========================================================================
-- WHAT IS DELIBERATELY *NOT* OPENED UP
-- ===========================================================================
-- SELECT ONLY. No INSERT, UPDATE or DELETE for anon/authenticated anywhere.
-- Writes keep going through the Edge Functions under service_role, which is
-- where all the money-side invariants live (payments.idempotency_key,
-- once-per-day message guards, the mark-overdue compare-and-set). A frontend
-- that could write directly would route around every one of them.
--
-- `public.users` IS EXCLUDED. It holds `pin_hash`, the credential for the
-- PIN-based auth this scaffolding exists to defer. Exposing password hashes to
-- a public key would be an own goal even in local dev, and it would make the
-- eventual auth work harder to reason about.
--
-- `public.webhook_events` IS EXCLUDED. It stores raw provider payloads, which
-- are the closest thing in this schema to unfiltered third-party PII.

-- ---------------------------------------------------------------------------
-- 1. Table privileges (fixes the 42501)
-- ---------------------------------------------------------------------------
GRANT SELECT ON public.organizations      TO anon, authenticated;
GRANT SELECT ON public.locations          TO anon, authenticated;
GRANT SELECT ON public.members            TO anon, authenticated;
GRANT SELECT ON public.membership_plans   TO anon, authenticated;
GRANT SELECT ON public.memberships        TO anon, authenticated;
GRANT SELECT ON public.payments           TO anon, authenticated;
GRANT SELECT ON public.attendance         TO anon, authenticated;
GRANT SELECT ON public.whatsapp_messages  TO anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. Permissive read policies (fixes the 42704)
--
-- Every one is named `local_dev_read_*` so a single LIKE query proves whether
-- any of them survived onto a database where they must not exist. Do not
-- rename them; that greppability is the safety net.
-- ---------------------------------------------------------------------------
CREATE POLICY local_dev_read_organizations ON public.organizations
  FOR SELECT TO anon, authenticated USING (true);

CREATE POLICY local_dev_read_locations ON public.locations
  FOR SELECT TO anon, authenticated USING (true);

CREATE POLICY local_dev_read_members ON public.members
  FOR SELECT TO anon, authenticated USING (true);

CREATE POLICY local_dev_read_membership_plans ON public.membership_plans
  FOR SELECT TO anon, authenticated USING (true);

CREATE POLICY local_dev_read_memberships ON public.memberships
  FOR SELECT TO anon, authenticated USING (true);

CREATE POLICY local_dev_read_payments ON public.payments
  FOR SELECT TO anon, authenticated USING (true);

CREATE POLICY local_dev_read_attendance ON public.attendance
  FOR SELECT TO anon, authenticated USING (true);

CREATE POLICY local_dev_read_whatsapp_messages ON public.whatsapp_messages
  FOR SELECT TO anon, authenticated USING (true);

-- ---------------------------------------------------------------------------
-- 3. A comment on every table, so the warning is visible from psql \d+ and
--    from Studio's table view — not only to whoever opens this file.
-- ---------------------------------------------------------------------------
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'organizations','locations','members','membership_plans',
    'memberships','payments','attendance','whatsapp_messages'
  ] LOOP
    EXECUTE format(
      'COMMENT ON TABLE public.%I IS %L', t,
      'LOCAL DEV ONLY: a permissive policy (local_dev_read_' || t ||
      ') currently allows anon/authenticated to read ALL tenants. ' ||
      'Must be removed before staging. See migration ' ||
      '20260823160000_LOCAL_DEV_ONLY_permissive_read_policies.sql'
    );
  END LOOP;
END;
$$;

-- ###########################################################################
-- ROLLBACK — run this before staging, then delete this file
-- ###########################################################################
--
-- DROP POLICY IF EXISTS local_dev_read_organizations     ON public.organizations;
-- DROP POLICY IF EXISTS local_dev_read_locations         ON public.locations;
-- DROP POLICY IF EXISTS local_dev_read_members           ON public.members;
-- DROP POLICY IF EXISTS local_dev_read_membership_plans  ON public.membership_plans;
-- DROP POLICY IF EXISTS local_dev_read_memberships       ON public.memberships;
-- DROP POLICY IF EXISTS local_dev_read_payments          ON public.payments;
-- DROP POLICY IF EXISTS local_dev_read_attendance        ON public.attendance;
-- DROP POLICY IF EXISTS local_dev_read_whatsapp_messages ON public.whatsapp_messages;
--
-- REVOKE SELECT ON public.organizations     FROM anon, authenticated;
-- REVOKE SELECT ON public.locations         FROM anon, authenticated;
-- REVOKE SELECT ON public.members           FROM anon, authenticated;
-- REVOKE SELECT ON public.membership_plans  FROM anon, authenticated;
-- REVOKE SELECT ON public.memberships       FROM anon, authenticated;
-- REVOKE SELECT ON public.payments          FROM anon, authenticated;
-- REVOKE SELECT ON public.attendance        FROM anon, authenticated;
-- REVOKE SELECT ON public.whatsapp_messages FROM anon, authenticated;
--
-- COMMENT ON TABLE public.organizations     IS NULL;
-- COMMENT ON TABLE public.locations         IS NULL;
-- COMMENT ON TABLE public.members           IS NULL;
-- COMMENT ON TABLE public.membership_plans  IS NULL;
-- COMMENT ON TABLE public.memberships       IS NULL;
-- COMMENT ON TABLE public.payments          IS NULL;
-- COMMENT ON TABLE public.attendance        IS NULL;
-- COMMENT ON TABLE public.whatsapp_messages IS NULL;
--
-- ###########################################################################
