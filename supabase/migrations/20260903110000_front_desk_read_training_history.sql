-- front_desk gains READ-ONLY access to training_notes / body_measurements
-- for members at their own location — needed for the new Member Detail
-- page's "Personal Training" session-history section, which the task framed
-- as an "owner/front-desk view" but the existing RLS only covered
-- owner (FOR ALL) and the assigned coach (FOR ALL). Verified empirically
-- before writing this: front_desk had NO branch at all on either table, so
-- coachWrites.getSessionHistory() called from a front_desk session would
-- have silently returned zero rows — indistinguishable from "no sessions
-- logged" rather than "you can't see this".
--
-- ============================================================================
-- WHY A NEW POLICY, NOT AN EDIT TO THE EXISTING ONE
-- ============================================================================
-- Both tables' existing tenant_isolation_* policies are FOR ALL (single USING
-- + WITH CHECK pair covering SELECT/INSERT/UPDATE/DELETE together). front_desk
-- must stay read-only here — they don't log training sessions or record
-- measurements, only coaches do — so folding them into that FOR ALL policy
-- would also need to either grant them write (wrong) or split the existing
-- policy's read/write halves apart (touches a real, working, already-audited
-- policy for no reason). A separate FOR SELECT PERMISSIVE policy is additive
-- and OR's with the existing one for SELECT only; INSERT/UPDATE/DELETE are
-- untouched, still coach/owner-only exactly as before.
--
-- Same location-scoping helper pt_packages' own front_desk branch already
-- uses (pt_member_at_location, 20260829091200) — same trust boundary as
-- everywhere else front_desk is scoped to "their branch's members".
--
-- The org_not_suspended RESTRICTIVE policy on both tables is FOR ALL, so it
-- already applies to these new SELECT policies too — nothing to add there.
-- ============================================================================

CREATE POLICY front_desk_read_training_notes ON public.training_notes
  FOR SELECT
  USING (
    organization_id = (auth.jwt() ->> 'org_id')::uuid
    AND (auth.jwt() ->> 'app_role') = 'front_desk'
    AND public.pt_member_at_location(member_id, (auth.jwt() ->> 'location_id')::uuid)
  );

CREATE POLICY front_desk_read_body_measurements ON public.body_measurements
  FOR SELECT
  USING (
    organization_id = (auth.jwt() ->> 'org_id')::uuid
    AND (auth.jwt() ->> 'app_role') = 'front_desk'
    AND public.pt_member_at_location(member_id, (auth.jwt() ->> 'location_id')::uuid)
  );
