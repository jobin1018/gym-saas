-- membership_renewal_amount(): the ONE place that decides what a membership's
-- next renewal costs. Used by send-renewal-reminder (service_role) so the rule
-- is testable from SQL without creating a live Razorpay payment link.
--
-- THE RULE
--   plan is a BUNDLE (plan.total_price set) AND the membership's duration is the
--   bundle's own duration  -> plan.total_price             (the fixed price)
--   anything else          -> plan.amount x duration_months (unchanged rule)
--
-- WHY total_price AND NOT amount x duration FOR A BUNDLE: plan.amount is the
-- monthly rate rounded to 2 dp, so amount x duration drifts from the bundle
-- price whenever it doesn't divide evenly (4500 / 7 months = 642.86; x7 =
-- 4500.02). A renewal must bill exactly the bundle price.
--
-- A bundle membership whose duration was corrected away from the bundle's own
-- (update_membership_duration) is, by definition, no longer the bundle as
-- sold, and renews at rate x its own duration — same as any monthly plan.
--
-- Like the pre-existing non-bundle rule this reads the CURRENT plan, not the
-- membership's signup snapshot: a plan price change applies to the next
-- renewal. Non-bundle plans behave exactly as before.
--
-- Period extension needs no change: razorpay-webhook and record_manual_payment
-- extend by memberships.duration_months, which for a bundle already includes
-- the bonus months (6 = 3 paid + 3 free).

CREATE FUNCTION public.membership_renewal_amount(p_membership_id uuid)
RETURNS numeric
LANGUAGE sql
STABLE
SET search_path = public, pg_temp
AS $$
  SELECT CASE
           WHEN mp.total_price IS NOT NULL AND ms.duration_months = mp.duration_months
             THEN mp.total_price
           ELSE mp.amount * ms.duration_months
         END
    FROM public.memberships ms
    JOIN public.membership_plans mp ON mp.id = ms.plan_id
   WHERE ms.id = p_membership_id;
$$;

COMMENT ON FUNCTION public.membership_renewal_amount(uuid) IS
  'Renewal charge in rupees: plan.total_price for a bundle membership at the '
  'bundle''s own duration, otherwise plan.amount x duration_months. NULL if the '
  'membership does not exist. SECURITY INVOKER; granted to service_role only.';

REVOKE ALL ON FUNCTION public.membership_renewal_amount(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.membership_renewal_amount(uuid) TO service_role;
