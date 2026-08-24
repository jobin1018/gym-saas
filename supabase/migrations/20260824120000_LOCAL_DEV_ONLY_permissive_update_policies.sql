-- ###########################################################################
-- #                                                                         #
-- #   ██  LOCAL DEV ONLY — MUST BE REPLACED BEFORE STAGING  ██              #
-- #                                                                         #
-- #   Companion to 20260823160000_LOCAL_DEV_ONLY_permissive_read_policies   #
-- #   and 20260823170000_LOCAL_DEV_ONLY_permissive_write_policies. Those    #
-- #   opened READ and INSERT. This one opens UPDATE — same tables, same     #
-- #   reasoning, one verb wider: a public anon key can now MODIFY any       #
-- #   member or membership in ANY organization, not just create one.        #
-- #                                                                         #
-- #   All three files must be rolled back and deleted together.             #
-- #                                                                         #
-- #   VERIFY WITH:                                                          #
-- #     select * from pg_policies                                          #
-- #      where schemaname = 'public' and policyname like 'local_dev_%';    #
-- #     -- MUST return zero rows on any non-local database.                 #
-- #                                                                         #
-- ###########################################################################
--
-- ===========================================================================
-- WHY UPDATE, AND WHY ONLY THESE TWO TABLES
-- ===========================================================================
-- Unblocks `supabase.from('members').update(...)` / `.from('memberships')
-- .update(...)` from the browser, for an Edit Member screen. Same scope as the
-- INSERT migration this mirrors, and the same tables it named as the pair a UI
-- actually needs (a member's plan/status lives on memberships, not members).
--
-- Still NOT granted: DELETE, and still NOT extended to payments,
-- whatsapp_messages, or anything else with a procedural invariant (see the
-- INSERT migration's note — those stay behind Edge Functions on purpose).
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 1. Table privileges
-- ---------------------------------------------------------------------------
GRANT UPDATE ON public.members     TO anon, authenticated;
GRANT UPDATE ON public.memberships TO anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. Permissive UPDATE policies
--
-- Both USING and WITH CHECK: on UPDATE, Postgres checks the OLD row against
-- USING (may this row be touched at all?) and the NEW row against WITH CHECK
-- (is the row legal after the edit?). `true`/`true` means "any row, any
-- tenant, any edit" — same dev-hack meaning as the INSERT policies' WITH
-- CHECK (true). The real policy replaces both with the same JWT-org check:
--     USING      (organization_id = (auth.jwt() ->> 'org_id')::uuid)
--     WITH CHECK (organization_id = (auth.jwt() ->> 'org_id')::uuid)
-- ---------------------------------------------------------------------------
CREATE POLICY local_dev_update_members ON public.members
  FOR UPDATE TO anon, authenticated USING (true) WITH CHECK (true);

CREATE POLICY local_dev_update_memberships ON public.memberships
  FOR UPDATE TO anon, authenticated USING (true) WITH CHECK (true);

-- ###########################################################################
-- ROLLBACK — run with the other two migrations' rollback, then delete all three
-- ###########################################################################
--
-- DROP POLICY IF EXISTS local_dev_update_members     ON public.members;
-- DROP POLICY IF EXISTS local_dev_update_memberships ON public.memberships;
--
-- REVOKE UPDATE ON public.members     FROM anon, authenticated;
-- REVOKE UPDATE ON public.memberships FROM anon, authenticated;
--
-- ###########################################################################
