-- Bundle plans: a membership plan can carry a default duration, a FIXED total
-- price and free bonus months, e.g. "6 month (3 months + 3 free) = Rs 4,500"
-- => duration_months 6, total_price 4500, bonus_months 3.
--
-- ============================================================================
-- THE MISTAKE THIS REMOVES
-- ============================================================================
-- membership_plans.amount is the MONTHLY RATE and every code path multiplies it
-- by memberships.duration_months (trg_memberships_derive_total_price,
-- send-renewal-reminder, seed, reports). A plan named "3 month" saved with
-- amount 3000 (the price of all three months) therefore charged 9000. A bundle
-- states the total explicitly and DERIVES the rate, so the total can no longer
-- be typed into the rate field by mistake.
--
-- ============================================================================
-- NEW COLUMNS  (membership_plans)
-- ============================================================================
--   duration_months  int  NULL      default duration of this plan, 1..36.
--                                   NULL for an ordinary monthly-rate plan.
--   total_price      numeric NULL   fixed price for the whole duration.
--                                   NOT NULL => this plan is a BUNDLE.
--   bonus_months     int NOT NULL 0 free months INSIDE duration_months
--                                   (6 = 3 paid + 3 free; the member's period
--                                   is the full 6, the price covers 3).
-- Constraints (all rejected at the table, whoever writes):
--   * total_price requires duration_months
--   * duration_months between 1 and 36 when set
--   * bonus_months >= 0, and < duration_months when duration_months is set;
--     bonus_months must be 0 when duration_months is not set
--   * bonus_months > 0 requires total_price. NOT in the original ask: without a
--     fixed total there is no price to attach "free months" to, and the plain
--     amount x duration rule would silently charge for the free months.
--   * total_price >= 0 and fits NUMERIC(10,2)
--
-- ============================================================================
-- amount STAYS THE MONTHLY RATE — kept in step by a TRIGGER
-- ============================================================================
-- For a bundle, amount = round(total_price / duration_months, 2), set by the
-- BEFORE INSERT OR UPDATE trigger membership_plans_derive_amount(). A trigger
-- (not a generated column) because amount is an existing, writable, NOT NULL
-- column that every current reader and the amount-sanity CHECK rely on; a
-- trigger leaves its type and name alone. Whatever amount the caller sends for
-- a bundle is overwritten, so the two cannot disagree (a stale form that still
-- posts amount=3000 for a 3-month/3000 bundle gets 1000, not 3000).
-- Non-bundle plans (total_price NULL) are never touched: existing plans behave
-- exactly as before and no existing row is modified by this migration.
--
-- ROUNDING: amount is NUMERIC(10,2), so amount x duration only equals
-- total_price when total_price divides evenly (4500/6 = 750.00 exactly;
-- 4500/7 = 642.86, x7 = 4500.02). Anything that must charge the bundle price
-- therefore reads total_price, not amount x duration — see
-- 20261030090500_membership_renewal_amount.sql.
--
-- ============================================================================
-- memberships.bonus_months — a SNAPSHOT
-- ============================================================================
-- Copied from the plan when the membership is created (and only when the
-- membership is created at the plan's own duration), so later plan edits do
-- not rewrite history. CHECK bonus_months >= 0 AND bonus_months <
-- duration_months.
--
-- ============================================================================
-- MEMBERSHIP CREATION on a bundle (trg_memberships_derive_total_price, replaced)
-- ============================================================================
--   duration_months = plan.duration_months   -> total_price := plan.total_price
--                                               bonus_months := plan.bonus_months
--                                               (each only if the caller left it
--                                               unset: total NULL / bonus 0)
--   any other duration                       -> falls back to the existing rule
--                                               plan.amount x duration; bonus 0.
--                                               A caller may still pass an
--                                               explicit total_price to override.
--   current_period_end omitted               -> start_date + duration_months
--                                               (previously a NOT NULL error;
--                                               supplying it still wins).
-- LIMIT: memberships.duration_months is NOT NULL DEFAULT 1, so the database
-- cannot tell "caller omitted it" from "caller sent 1". Selecting a bundle must
-- therefore PREFILL duration_months from the plan on the client; the DB only
-- prices correctly once it receives that duration.
--
-- ============================================================================
-- GRANTS / RLS — nothing to change
-- ============================================================================
-- membership_plans: table-wide GRANT SELECT (anon, authenticated, service_role)
-- and GRANT INSERT, UPDATE (authenticated), policy tenant_isolation_plans with
-- WITH CHECK owner/front_desk (20260829100000). All table-scoped, so the three
-- new columns inherit them; the row policy has no column dimension. memberships
-- likewise (table-wide UPDATE, tenant_isolation_memberships). Verified by the
-- rls-test.sh bundle section against real owner/front_desk/coach sessions.
-- ============================================================================

ALTER TABLE public.membership_plans
  ADD COLUMN duration_months INTEGER,
  ADD COLUMN total_price     NUMERIC(10,2),
  ADD COLUMN bonus_months    INTEGER NOT NULL DEFAULT 0;

ALTER TABLE public.membership_plans
  ADD CONSTRAINT membership_plans_duration_range
    CHECK (duration_months IS NULL OR duration_months BETWEEN 1 AND 36),
  ADD CONSTRAINT membership_plans_total_needs_duration
    CHECK (total_price IS NULL OR duration_months IS NOT NULL),
  ADD CONSTRAINT membership_plans_total_nonneg
    CHECK (total_price IS NULL OR total_price >= 0),
  ADD CONSTRAINT membership_plans_bonus_range
    CHECK (
      bonus_months >= 0
      AND (
        (duration_months IS NULL AND bonus_months = 0)
        OR (duration_months IS NOT NULL AND bonus_months < duration_months)
      )
    ),
  ADD CONSTRAINT membership_plans_bonus_needs_total
    CHECK (bonus_months = 0 OR total_price IS NOT NULL);

COMMENT ON COLUMN public.membership_plans.amount IS
  'Effective MONTHLY rate in rupees. Entered directly for an ordinary plan; for '
  'a bundle (total_price set) it is derived as round(total_price / '
  'duration_months, 2) by membership_plans_derive_amount() and any supplied '
  'value is overwritten. Never the price of the whole duration.';
COMMENT ON COLUMN public.membership_plans.duration_months IS
  'Default duration of this plan in months (1..36), including bonus_months. '
  'NULL for an ordinary monthly-rate plan.';
COMMENT ON COLUMN public.membership_plans.total_price IS
  'Fixed price for the whole duration_months (bundle). NOT NULL marks the plan '
  'as a bundle; renewals and new memberships at the plan''s own duration are '
  'billed this amount, not amount x duration (rounding).';
COMMENT ON COLUMN public.membership_plans.bonus_months IS
  'Free months inside duration_months (e.g. 6 = 3 paid + 3 free => 3). 0 for '
  'ordinary plans. Requires total_price.';

CREATE FUNCTION public.membership_plans_derive_amount()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
BEGIN
  IF NEW.total_price IS NOT NULL AND NEW.duration_months IS NOT NULL THEN
    NEW.amount := round(NEW.total_price / NEW.duration_months, 2);
  END IF;
  RETURN NEW;
END;
$$;

-- BEFORE triggers run before NOT NULL / CHECK enforcement, so a bundle insert
-- may omit amount entirely.
CREATE TRIGGER trg_membership_plans_derive_amount
  BEFORE INSERT OR UPDATE ON public.membership_plans
  FOR EACH ROW EXECUTE FUNCTION public.membership_plans_derive_amount();

-- ---------------------------------------------------------------------------
-- memberships.bonus_months
-- ---------------------------------------------------------------------------
ALTER TABLE public.memberships
  ADD COLUMN bonus_months INTEGER NOT NULL DEFAULT 0;

ALTER TABLE public.memberships
  ADD CONSTRAINT memberships_bonus_range
    CHECK (bonus_months >= 0 AND bonus_months < duration_months);

COMMENT ON COLUMN public.memberships.bonus_months IS
  'Free months included in duration_months, snapshotted from the plan at '
  'creation (bundle plans only; 0 otherwise). Not recomputed when the plan '
  'changes. update_membership_duration() resets it to 0 when the duration '
  'moves away from the bundle''s own.';

-- ---------------------------------------------------------------------------
-- Membership creation: replace the INSERT-only derive trigger function in place
-- (same name, same trigger) with the bundle-aware version.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.memberships_derive_total_price()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_rate     numeric;
  v_pdur     integer;
  v_ptotal   numeric;
  v_pbonus   integer;
BEGIN
  SELECT mp.amount, mp.duration_months, mp.total_price, mp.bonus_months
    INTO v_rate, v_pdur, v_ptotal, v_pbonus
    FROM public.membership_plans mp
   WHERE mp.id = NEW.plan_id;
  -- Unresolvable plan_id: leave everything; the FK raises a clear error.

  IF v_ptotal IS NOT NULL AND NEW.duration_months = v_pdur THEN
    -- Bundle sold as designed: the fixed price and its bonus months.
    IF NEW.total_price IS NULL THEN NEW.total_price := v_ptotal; END IF;
    IF NEW.bonus_months = 0    THEN NEW.bonus_months := v_pbonus; END IF;
  ELSIF NEW.total_price IS NULL THEN
    -- Ordinary plan, or a bundle at a different duration: rate x duration.
    NEW.total_price := v_rate * NEW.duration_months;
  END IF;

  IF NEW.current_period_end IS NULL THEN
    NEW.current_period_end := (NEW.start_date + (NEW.duration_months || ' months')::interval)::date;
  END IF;

  RETURN NEW;
END;
$$;
