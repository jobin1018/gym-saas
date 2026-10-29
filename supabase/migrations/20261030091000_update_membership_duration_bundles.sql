-- update_membership_duration(): bundle-plan awareness + bonus_months.
-- Supersedes 20261029090000's function body. Behaviour, error codes and the
-- audit trail for memberships on ORDINARY plans (plan.total_price NULL) are
-- unchanged; the RETURN TABLE gains one trailing column (bonus_months), which
-- forces a DROP + CREATE (CREATE OR REPLACE cannot change a return type).
-- Additive for PostgREST clients: they just see one more JSON field.
--
-- ============================================================================
-- WHAT HAPPENS TO A BUNDLE MEMBERSHIP  (plan.total_price IS NOT NULL)
-- ============================================================================
-- "At the bundle's duration" = p_duration_months = plan.duration_months.
--
--  1. NEW duration = the bundle's own duration
--       total_price  := p_total_price if given, else plan.total_price (the fixed
--                       bundle price — not a guess, so no total is required)
--       bonus_months := plan.bonus_months
--     e.g. a "6 month (3+3 free) = 4500" bundle signed up with duration 3 by
--     mistake (stored 750 x 3 = 2250, bonus 0) is corrected to 6 -> 4500, bonus 3.
--
--  2. NEW duration is anything else
--       p_total_price REQUIRED -> otherwise total_required (HINT carries the
--       monthly-rate figure). Unlike an ordinary plan, a bundle's effective
--       monthly rate already has the free months baked in, so rate x months
--       would quietly price a 3-month purchase at the 6-month discount; staff
--       must state the total.
--       bonus_months := 0 (the free-months promise belongs to the bundle as
--       sold) — unless the duration is not actually changing, in which case
--       the existing bonus_months is kept.
--
--  3. "Derivable stored total" (the existing no-guessing rule) now also accepts
--     a stored total equal to plan.total_price when the membership is at the
--     bundle's duration, so a correctly-priced bundle membership isn't treated
--     as "negotiated" just because rate(2dp) x duration drifts from it.
--
-- ORDINARY plan memberships: total as before (explicit, or rate x duration if
-- the stored total is rate x old duration, else total_required); bonus_months
-- kept if the duration is unchanged, else 0 (it is 0 for every such row that
-- this feature itself created).
--
-- AUDIT: membership_duration_changes gains old_bonus_months / new_bonus_months
-- (nullable: rows written before this migration have NULL = not recorded).
--
-- RENEWALS after a correction: a bundle membership left at the bundle's
-- duration renews at plan.total_price; one moved to another duration renews at
-- plan.amount x its own duration (membership_renewal_amount()).
--
-- ERROR CODES: unchanged (not_authorized, organization_suspended,
-- duration_invalid, total_invalid, membership_not_found, membership_frozen,
-- membership_cancelled, total_required).
-- ============================================================================

ALTER TABLE public.membership_duration_changes
  ADD COLUMN old_bonus_months INTEGER,
  ADD COLUMN new_bonus_months INTEGER;

DROP FUNCTION public.update_membership_duration(uuid, integer, numeric);

CREATE FUNCTION public.update_membership_duration(
  p_membership_id   uuid,
  p_duration_months integer,
  p_total_price     numeric DEFAULT NULL
)
RETURNS TABLE(
  membership_id       uuid,
  duration_months     integer,
  current_period_end  date,
  total_price         numeric,
  status              text,
  has_payments        boolean,
  bonus_months        integer
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_org             uuid := (auth.jwt() ->> 'org_id')::uuid;
  v_user            uuid := (auth.jwt() ->> 'user_id')::uuid;
  v_role            text := (auth.jwt() ->> 'app_role');
  v_caller_location uuid;
  v_member_id       uuid;
  v_member_location uuid;
  v_plan_id         uuid;
  v_status          text;
  v_start           date;
  v_old_end         date;
  v_old_duration    integer;
  v_old_total       numeric;
  v_old_bonus       integer;
  v_rate            numeric;
  v_plan_duration   integer;
  v_plan_total      numeric;
  v_plan_bonus      integer;
  v_is_bundle       boolean;
  v_at_bundle_shape boolean;
  v_derivable       boolean;
  v_new_end         date;
  v_new_total       numeric;
  v_new_bonus       integer;
  v_new_status      text;
  v_has_payments    boolean;
BEGIN
  IF v_org IS NULL OR v_user IS NULL THEN
    RAISE EXCEPTION 'update_membership_duration requires an authenticated staff session';
  END IF;

  IF v_role NOT IN ('owner', 'front_desk') THEN
    RAISE EXCEPTION 'not_authorized' USING errcode = '42501';
  END IF;

  IF NOT public.current_org_active() THEN
    RAISE EXCEPTION 'organization_suspended' USING errcode = 'P0001';
  END IF;

  IF p_duration_months IS NULL OR p_duration_months < 1 OR p_duration_months > 36 THEN
    RAISE EXCEPTION 'duration_invalid' USING DETAIL = '1..36';
  END IF;

  IF p_total_price IS NOT NULL AND (p_total_price < 0 OR p_total_price > 99999999.99) THEN
    RAISE EXCEPTION 'total_invalid' USING DETAIL = '0..99999999.99';
  END IF;

  SELECT ms.member_id, ms.plan_id, ms.status, ms.start_date, ms.current_period_end,
         ms.duration_months, ms.total_price, ms.bonus_months
    INTO v_member_id, v_plan_id, v_status, v_start, v_old_end, v_old_duration, v_old_total, v_old_bonus
    FROM public.memberships ms
   WHERE ms.id = p_membership_id
     AND ms.organization_id = v_org
     FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'membership_not_found';
  END IF;

  IF v_role = 'front_desk' THEN
    v_caller_location := (auth.jwt() ->> 'location_id')::uuid;
    SELECT mm.location_id INTO v_member_location
      FROM public.members mm WHERE mm.id = v_member_id;
    IF v_caller_location IS NULL OR v_member_location IS DISTINCT FROM v_caller_location THEN
      RAISE EXCEPTION 'membership_not_found';
    END IF;
  END IF;

  IF v_status = 'frozen' THEN
    RAISE EXCEPTION 'membership_frozen'
      USING HINT = 'Unfreeze the membership first, then correct its duration.';
  ELSIF v_status = 'cancelled' THEN
    RAISE EXCEPTION 'membership_cancelled';
  END IF;

  v_new_end := (v_start + (p_duration_months || ' months')::interval)::date;

  SELECT mp.amount, mp.duration_months, mp.total_price, mp.bonus_months
    INTO v_rate, v_plan_duration, v_plan_total, v_plan_bonus
    FROM public.membership_plans mp WHERE mp.id = v_plan_id;

  v_is_bundle       := v_plan_total IS NOT NULL;
  v_at_bundle_shape := v_is_bundle AND p_duration_months = v_plan_duration;

  IF p_total_price IS NOT NULL THEN
    v_new_total := p_total_price;
  ELSIF v_is_bundle AND NOT v_at_bundle_shape THEN
    -- Leaving the bundle's own duration: the price is the user's to state.
    RAISE EXCEPTION 'total_required'
      USING DETAIL = 'This membership is on a bundle plan (fixed total for a fixed duration); '
                     'a different duration has no defined price, pass p_total_price.',
            HINT = format('plan monthly rate x %s months = %s', p_duration_months, v_rate * p_duration_months);
  ELSE
    -- Only derive when the stored total is itself derivable from the plan.
    v_derivable := v_rate IS NOT NULL AND (
         v_old_total = v_rate * v_old_duration
      OR (v_is_bundle AND v_old_duration = v_plan_duration AND v_old_total = v_plan_total)
    );
    IF NOT COALESCE(v_derivable, false) THEN
      RAISE EXCEPTION 'total_required'
        USING DETAIL = 'This membership''s total is not plan rate x duration (negotiated, '
                       'rate changed since signup, or no plan); pass p_total_price.',
              HINT = CASE WHEN v_rate IS NULL THEN NULL
                          ELSE format('plan rate x %s months = %s', p_duration_months, v_rate * p_duration_months) END;
    END IF;
    v_new_total := CASE WHEN v_at_bundle_shape THEN v_plan_total
                        ELSE v_rate * p_duration_months END;
  END IF;

  v_new_bonus := CASE
                   WHEN v_at_bundle_shape               THEN v_plan_bonus
                   WHEN p_duration_months = v_old_duration THEN v_old_bonus
                   ELSE 0
                 END;

  v_new_status := v_status;
  IF v_status IN ('past_due', 'expired') AND v_new_end >= CURRENT_DATE THEN
    v_new_status := 'active';
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM public.payments p
     WHERE p.membership_id = p_membership_id
       AND p.status IN ('success', 'manual')
  ) INTO v_has_payments;

  IF v_new_status IS DISTINCT FROM v_status THEN
    PERFORM set_config('app.membership_status_managed_write', 'on', true);
  END IF;

  UPDATE public.memberships ms
     SET duration_months    = p_duration_months,
         current_period_end = v_new_end,
         total_price        = v_new_total,
         bonus_months       = v_new_bonus,
         status             = v_new_status
   WHERE ms.id = p_membership_id;

  INSERT INTO public.membership_duration_changes
    (organization_id, membership_id, changed_by,
     old_duration_months, new_duration_months, old_period_end, new_period_end,
     old_total_price, new_total_price, old_status, new_status,
     total_was_explicit, had_payments, old_bonus_months, new_bonus_months)
  VALUES
    (v_org, p_membership_id, v_user,
     v_old_duration, p_duration_months, v_old_end, v_new_end,
     v_old_total, v_new_total, v_status, v_new_status,
     p_total_price IS NOT NULL, v_has_payments, v_old_bonus, v_new_bonus);

  RETURN QUERY SELECT p_membership_id, p_duration_months, v_new_end, v_new_total,
                      v_new_status, v_has_payments, v_new_bonus;
END;
$function$;

COMMENT ON FUNCTION public.update_membership_duration(uuid, integer, numeric) IS
  'Owner/front_desk corrects memberships.duration_months after signup: '
  'current_period_end = start_date + new duration, total_price = p_total_price '
  'or the plan-derived figure (total_required when it cannot be derived), '
  'past_due/expired -> active when the new end is not in the past, audit row '
  'in membership_duration_changes, has_payments flag. Bundle plans: at the '
  'bundle''s own duration the total snaps to plan.total_price and bonus_months '
  'to the plan''s; at any other duration p_total_price is required and '
  'bonus_months resets to 0. Refuses frozen and cancelled. SECURITY DEFINER.';

REVOKE ALL ON FUNCTION public.update_membership_duration(uuid, integer, numeric) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.update_membership_duration(uuid, integer, numeric) TO authenticated;
