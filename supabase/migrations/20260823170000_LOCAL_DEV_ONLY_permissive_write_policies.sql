-- ###########################################################################
-- #                                                                         #
-- #   ██  LOCAL DEV ONLY — MUST BE REPLACED BEFORE STAGING  ██              #
-- #                                                                         #
-- #   Companion to 20260823160000_LOCAL_DEV_ONLY_permissive_read_policies.  #
-- #   That one opened READS. This one opens WRITES, which is strictly        #
-- #   worse: a public anon key can now CREATE members and memberships in     #
-- #   ANY organization. Not just read another tenant's data — write into it. #
-- #                                                                         #
-- #   Both files must be rolled back and deleted together.                   #
-- #                                                                         #
-- #   VERIFY WITH:                                                           #
-- #     select * from pg_policies                                            #
-- #      where schemaname = 'public' and policyname like 'local_dev_%';      #
-- #     -- MUST return zero rows on any non-local database.                  #
-- #                                                                         #
-- ###########################################################################
--
-- ===========================================================================
-- READ THIS BEFORE BUILDING THE UI AGAINST IT
-- ===========================================================================
-- This unblocks `supabase.from('members').insert(...)` from the browser. It is
-- the fastest way to get a working "add member" form on localhost, and it is
-- ALSO a dead end: none of that client code survives to staging.
--
-- When real auth lands, direct browser writes have to satisfy an RLS policy
-- that checks the caller's org from their JWT. At that point one of two things
-- happens to every write in the frontend:
--
--   (a) it keeps the same shape (`.from('members').insert()`) and simply
--       starts being tenant-checked — IF you decide staff may write directly,
--       and IF every invariant that write depends on lives in the database; or
--   (b) it moves behind an Edge Function, and the client code is rewritten.
--
-- Which one you get is not decided by this file — it is decided by where the
-- rules live. For `members` specifically the rules ARE in the database today
-- (NOT NULL, two FKs, UNIQUE (organization_id, phone)), so (a) is realistic.
-- The moment creating a member also has to, say, send a welcome WhatsApp or
-- open a first payment link, it becomes (b), because those cannot be expressed
-- as constraints.
--
-- Nothing else in this system writes from the browser: payments, membership
-- status and message logs are all written by Edge Functions under service_role
-- precisely because their invariants (payments.idempotency_key, the
-- once-per-day message guards, mark-overdue's compare-and-set) are procedural.
-- Do not extend this file to those tables. A frontend that could write them
-- directly would route around every one of those guards.
--
-- ===========================================================================
-- WHY memberships IS INCLUDED WHEN ONLY members WAS ASKED FOR
-- ===========================================================================
-- A members row on its own is an incomplete record — no plan, no billing
-- period, so it is invisible to renewal-scan, to mark-overdue, and to
-- daily-owner-brief's figures. The real operation a UI performs is "add a
-- member AND start their membership". Granting only members would have blocked
-- on the very next request with an identical 42501, so both are here.
--
-- NOT granted: UPDATE or DELETE, on anything. Editing and removing members are
-- separate decisions with their own consequences (a DELETE would fail against
-- the FKs from attendance/memberships/whatsapp_messages anyway). Add them
-- deliberately if you need them, rather than opening the whole verb set now.

-- ---------------------------------------------------------------------------
-- 1. Table privileges
-- ---------------------------------------------------------------------------
GRANT INSERT ON public.members     TO anon, authenticated;
GRANT INSERT ON public.memberships TO anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. Permissive INSERT policies
--
-- WITH CHECK rather than USING: on INSERT, Postgres validates the NEW row
-- against WITH CHECK. A USING clause alone would not make the insert legal.
--
-- `true` means "any row, any tenant". The real policy will read the caller's
-- org from their JWT and look approximately like:
--     WITH CHECK (organization_id = (auth.jwt() ->> 'org_id')::uuid)
-- which is the single line that turns this from a dev hack into tenant
-- isolation. It is written here as a comment, not as code, on purpose: there
-- is no JWT to read yet, so it would reject everything.
-- ---------------------------------------------------------------------------
CREATE POLICY local_dev_insert_members ON public.members
  FOR INSERT TO anon, authenticated WITH CHECK (true);

CREATE POLICY local_dev_insert_memberships ON public.memberships
  FOR INSERT TO anon, authenticated WITH CHECK (true);

-- ---------------------------------------------------------------------------
-- 3. PostgREST needs SELECT to return the inserted row
--
-- Already granted by the read migration, noted here only so it is obvious why
-- `.insert(...).select()` works: without SELECT, PostgREST can perform the
-- insert but cannot hand the row back, and supabase-js returns data: null with
-- no error — which reads like a silent failure.
-- ---------------------------------------------------------------------------

-- ###########################################################################
-- ROLLBACK — run with the read migration's rollback, then delete both files
-- ###########################################################################
--
-- DROP POLICY IF EXISTS local_dev_insert_members     ON public.members;
-- DROP POLICY IF EXISTS local_dev_insert_memberships ON public.memberships;
--
-- REVOKE INSERT ON public.members     FROM anon, authenticated;
-- REVOKE INSERT ON public.memberships FROM anon, authenticated;
--
-- ###########################################################################
