-- membership_plans CRUD for owner / front_desk — direct authenticated write.
--
-- ============================================================================
-- DIRECT WRITE, NOT A FUNCTION — same reasoning as pt_packages (20260829092000)
-- ============================================================================
-- Creating or editing a plan is a single-row write into one table, post-login,
-- with no money movement, no external API call, and no secret. RLS can fully
-- express "an owner or front_desk of THIS org" — so an Edge Function would add
-- a network hop and a second copy of the authorization logic for nothing. The
-- functions in this project use service_role only where that does NOT hold
-- (pre-login, Admin API, cron, spends money). None of that applies here.
--
-- ============================================================================
-- WHAT CHANGES
-- ============================================================================
--   * GRANT INSERT, UPDATE to authenticated. NO DELETE grant, ever: plans are
--     soft-deactivated by setting `active = false` (the column already exists),
--     because live and historical memberships FK-reference membership_plans and
--     a hard delete would orphan them. "Delete a plan" in the UI is an UPDATE
--     to active = false.
--
--   * tenant_isolation_plans was USING-only (org match, no role branch). For a
--     FOR ALL policy that means INSERT/UPDATE inherit the USING expression as
--     their implicit WITH CHECK — i.e. once the grant above exists, ANY
--     authenticated role in the org (a coach included) could write. Add an
--     explicit WITH CHECK naming the two roles allowed to manage the plan
--     catalogue. USING is deliberately left untouched: every role in the org,
--     coaches included, legitimately READS plan names and prices.
--
--   * A sanity bound on amount (>= 0 and <= 1,000,000). Same spirit as
--     memberships.duration_months's 1..36 — it catches a fat-fingered monthly
--     rate on the new write path, not a real product limit. >= 0 (not > 0) so a
--     genuine comp / ₹0 plan is still allowed. Existing seed plans (1000–2800)
--     pass; if this fails on a real database that is bad data worth surfacing.
--
-- No RLS/grant change is needed for reads (already granted) or for other roles.
-- ============================================================================

GRANT INSERT, UPDATE ON public.membership_plans TO authenticated;

ALTER POLICY tenant_isolation_plans ON public.membership_plans
  WITH CHECK (
    organization_id = (auth.jwt() ->> 'org_id')::uuid
    AND (auth.jwt() ->> 'app_role') IN ('owner', 'front_desk')
  );

ALTER TABLE public.membership_plans
  ADD CONSTRAINT membership_plans_amount_sane
    CHECK (amount >= 0 AND amount <= 1000000);
