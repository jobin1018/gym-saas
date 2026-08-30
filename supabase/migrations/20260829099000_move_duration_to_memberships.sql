-- Correct the duration model: duration belongs to the MEMBERSHIP (the
-- per-member signup), not the plan. A plan is a type + a monthly rate.
--
-- ============================================================================
-- WHY THE PREVIOUS SHAPE WAS WRONG
-- ============================================================================
-- 20260829098000 put duration_months on membership_plans. That forces one
-- plan row per (plan-type x duration) combination — "Basic / 1 month",
-- "Basic / 3 months", "Basic / 12 months" — which is not what a plan is. A
-- plan is "Basic, Rs.1200/month". How long a given member commits for is a
-- property of THEIR signup.
--
-- ============================================================================
-- WHAT CHANGES
-- ============================================================================
-- membership_plans:
--   * DROP duration_months        -- was 20260829098000
--   * DROP billing_interval       -- the CHECK went in 20260829098000; the
--                                    column is now dead weight and, like
--                                    duration_months, it encodes cadence the
--                                    plan must not encode. Nothing reads it
--                                    (grep: schema only). Dropped, not left
--                                    "deprecated" — a wrong-model column with
--                                    no consumers is a landmine, and every
--                                    consumer that ever read either column
--                                    (razorpay-webhook, the frontend) is being
--                                    updated in the same change set.
--   * `amount` KEEPS its name. It already means "monthly rate" — renaming to
--     monthly_amount would ripple through razorpay-webhook,
--     send-renewal-reminder, daily-owner-brief, seed.sql, three frontend
--     files and several test.sh suites for a cosmetic gain. A COMMENT is
--     added instead; a rename can be a separate mechanical pass if wanted.
--
-- memberships:
--   * ADD duration_months INTEGER NOT NULL DEFAULT 1
--       CHECK (duration_months BETWEEN 1 AND 36)
--     Free integer — a member may sign for 1, 2, 7, 14... months, not a fixed
--     tier list. 1..36 is a data-entry sanity bound (three years), not a
--     product restriction. DEFAULT 1 makes this zero-regression: every
--     existing membership was monthly.
--   * ADD total_price NUMERIC(10,2)  -- signup-time price snapshot, see below
--
-- ============================================================================
-- PRICE: SNAPSHOT, NOT LIVE RECOMPUTE
-- ============================================================================
-- total_price = plan monthly rate * duration_months, captured on the
-- memberships row at signup and NOT recomputed afterwards.
--
-- Why snapshot: a plan's `amount` can be changed later. If price were always
-- recomputed as `plan.amount (current) * duration_months`, a member who
-- signed a 12-month deal at Rs.1200/mo would retroactively show the new rate
-- x 12 the day the gym raises Basic. Wrong for receipts, revenue history,
-- refunds and disputes. `payments.amount` is already a per-transaction
-- snapshot for exactly this reason; `pt_packages.price` is already a snapshot
-- too. This is the same discipline.
--
-- Why NOT also re-snapshot on renewal (razorpay-webhook): deliberately out of
-- scope. The user's stated goal is "signup pricing stays historically
-- accurate", and freezing at signup is the most literal, lowest-risk reading
-- (zero added surface on the money path). Per-renewal price history already
-- lives in payments.amount. If "current-period terms" is wanted on the
-- membership row later, that is a small follow-up (razorpay-webhook re-derives
-- total_price when it extends the period).
--
-- total_price is filled by a BEFORE INSERT trigger when the caller omits it,
-- so seed.sql / psql / the frontend all get the snapshot for free, and it
-- stays overridable (a negotiated total) by passing it explicitly — same
-- pattern as pt_packages_derive_sessions (20260829098500).
--
-- ============================================================================
-- GRANTS / RLS — nothing to change
-- ============================================================================
-- memberships already has table-wide GRANT SELECT/INSERT/UPDATE to
-- authenticated and anon SELECT (20260824141000) plus service_role
-- (20260823...). Table-scoped, so the two new columns are covered.
-- tenant_isolation_memberships is row-level (org + location via member) with
-- no column dimension. membership_plans grants/policy likewise unaffected by
-- dropping two columns. The derive trigger reads membership_plans.amount and
-- is SECURITY DEFINER, so it needs no caller grant.
-- ============================================================================

ALTER TABLE public.membership_plans DROP COLUMN duration_months;
ALTER TABLE public.membership_plans DROP COLUMN billing_interval;

COMMENT ON COLUMN public.membership_plans.amount IS
  'Monthly rate for this plan type, in rupees (NUMERIC(10,2)). Duration lives '
  'on memberships.duration_months; a membership''s total is amount * that.';

ALTER TABLE public.memberships
  ADD COLUMN duration_months INTEGER NOT NULL DEFAULT 1
    CHECK (duration_months BETWEEN 1 AND 36);

ALTER TABLE public.memberships
  ADD COLUMN total_price NUMERIC(10,2)
    CHECK (total_price IS NULL OR total_price >= 0);

COMMENT ON COLUMN public.memberships.duration_months IS
  'How many months this signup runs. Free integer 1..36 (sanity bound, not a '
  'tier list). current_period_end = start_date + this; a renewal payment is '
  'plan.amount * this.';
COMMENT ON COLUMN public.memberships.total_price IS
  'Signup-time snapshot of plan.amount * duration_months, in rupees. Frozen at '
  'signup so historical pricing survives later plan-rate changes. Filled by '
  'trg_memberships_derive_total_price when omitted; pass explicitly to record '
  'a negotiated total.';

-- Backfill existing rows (no-op on a fresh `db reset` — seed runs after
-- migrations — but correct for staging/prod where memberships already exist).
UPDATE public.memberships m
   SET total_price = mp.amount * m.duration_months
  FROM public.membership_plans mp
 WHERE mp.id = m.plan_id
   AND m.total_price IS NULL;

CREATE FUNCTION public.memberships_derive_total_price()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  -- Only when the caller left it unset. An explicit total_price is a
  -- negotiated override and is kept as-is. INSERT only — never recompute a
  -- live membership's recorded price out from under an audit trail.
  IF NEW.total_price IS NULL THEN
    SELECT mp.amount * NEW.duration_months
      INTO NEW.total_price
      FROM public.membership_plans mp
     WHERE mp.id = NEW.plan_id;
    -- If plan_id doesn't resolve, total_price stays NULL and the NOT NULL FK
    -- on plan_id raises a clear error a moment later — no need to duplicate
    -- that check here.
  END IF;
  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.memberships_derive_total_price() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.memberships_derive_total_price() FROM anon, authenticated, service_role;

CREATE TRIGGER trg_memberships_derive_total_price
  BEFORE INSERT ON public.memberships
  FOR EACH ROW EXECUTE FUNCTION public.memberships_derive_total_price();
