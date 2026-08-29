-- membership_plans: real multi-month durations. Drop the "monthly only" CHECK,
-- add duration_months as the single source of truth for how long one billing
-- period lasts.
--
-- ============================================================================
-- WHAT CHANGES
-- ============================================================================
--   * NEW  duration_months INTEGER NOT NULL DEFAULT 1  CHECK (> 0)
--   * DROP membership_plans_billing_interval_check
--       (the CHECK (billing_interval = 'monthly') from
--        20260822041613_create_core_schema.sql)
--
-- DEFAULT 1 is what makes this a zero-regression change for existing data:
-- every current plan row was, by that dropped CHECK, monthly — so 1 is not a
-- guess, it is the value the old constraint guaranteed. Any code that reads
-- duration_months off a pre-existing plan gets 1 and behaves exactly as the
-- hardcoded "+1 month" did.
--
-- ============================================================================
-- billing_interval — LEFT IN PLACE, deliberately, but see the recommendation
-- ============================================================================
-- The column stays (still TEXT NOT NULL DEFAULT 'monthly'), only its CHECK is
-- gone, because the ask was "remove the monthly-only CHECK", not "drop the
-- column". Nothing in the codebase reads billing_interval today (grep:
-- schema definition only), and duration_months is its strictly-more-
-- expressive replacement.
--
-- RECOMMENDATION (not done here — flagging for review): drop billing_interval
-- in a follow-up. An unconstrained free-text column that nothing maintains
-- and that can now silently disagree with duration_months ('monthly' next to
-- duration_months = 12) is a latent footgun. Keeping it is the more
-- conservative move for this migration; removing it is a one-line follow-up
-- once you've confirmed no external consumer (BI export, etc.) reads it.
--
-- ============================================================================
-- GRANTS / RLS — nothing to change, and why
-- ============================================================================
-- membership_plans already has table-wide GRANT SELECT to anon + authenticated
-- (20260824141000) and to service_role (20260823120000). Those grants are
-- table-scoped, not column-scoped, so a newly added column is readable by
-- every existing consumer (the frontend plan picker, razorpay-webhook's
-- period extension) with no further GRANT. tenant_isolation_plans is
-- org-scoped only, no role or column dimension — unaffected.
-- ============================================================================

ALTER TABLE public.membership_plans
  ADD COLUMN duration_months INTEGER NOT NULL DEFAULT 1
    CHECK (duration_months > 0);

ALTER TABLE public.membership_plans
  DROP CONSTRAINT membership_plans_billing_interval_check;

COMMENT ON COLUMN public.membership_plans.duration_months IS
  'Length of one billing period, in months (1/3/6/12/...). '
  'current_period_end = start_date + duration_months months. Replaces the '
  'dropped CHECK (billing_interval = ''monthly''); billing_interval is now a '
  'vestigial free-text column nothing reads.';
