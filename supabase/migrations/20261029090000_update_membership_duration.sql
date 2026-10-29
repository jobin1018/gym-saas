-- update_membership_duration() — owner/front_desk corrects a membership's
-- duration_months after signup (front desk typed the wrong duration), with the
-- end date and total recalculated consistently and an audit row left behind.
--
-- ============================================================================
-- WHY AN RPC AND NOT A DIRECT PATCH
-- ============================================================================
-- `authenticated` already has table-wide UPDATE on memberships, narrowed only
-- by tenant_isolation_memberships (owner org-wide; front_desk own location),
-- so today a PATCH of duration_months / current_period_end / total_price /
-- start_date is ALLOWED — but each column is independent. Nothing keeps
-- duration, end date and price in step, nothing records who changed what, and
-- no trigger recomputes total_price on UPDATE (the derive trigger is BEFORE
-- INSERT only). A hand-rolled PATCH of just duration_months silently leaves
-- the end date and price describing the OLD duration. This RPC changes the
-- three together, inside one transaction, and writes the audit trail.
--
-- ============================================================================
-- SECURITY DEFINER — same reasons as record_manual_payment
-- ============================================================================
--   * has_payments must be answerable for front_desk, but payments' RLS is
--     owner-only (front_desk reads zero rows by design).
--   * the audit table has no authenticated INSERT grant at all.
-- DEFINER bypasses RLS, so the checks RLS would have done are re-implemented
-- by hand: role, org, front_desk location scoping (masked as
-- membership_not_found — a front-desk operator must not learn that a
-- membership exists at another branch), suspended org.
--
-- ============================================================================
-- TOTAL PRICE — what is and is not guessed
-- ============================================================================
-- memberships has no rate column. total_price is a signup-time SNAPSHOT of
-- membership_plans.amount (monthly rate) x duration_months, filled by
-- trg_memberships_derive_total_price on INSERT only, and overridable with a
-- negotiated total (20260829099000). plan_id is NOT NULL, so every membership
-- has a plan; "custom price" therefore means a total that is NOT
-- plan.amount x current duration (a negotiated total, or a plan whose rate
-- changed since signup). Recomputing rate x new_duration over such a total
-- would silently overwrite a negotiated figure with a guess, so:
--   p_total_price given                          -> used as-is
--   stored total = plan.amount x OLD duration    -> recomputed plan.amount x NEW
--   anything else (custom / stale / NULL / no plan) -> total_required, with the
--     rate-based figure in the error HINT so the UI can offer it as a default.
--
-- ============================================================================
-- STATUS
-- ============================================================================
--   active | past_due | expired  -> correctable
--   frozen    -> membership_frozen  (unfreeze first: unfreeze_membership shifts
--                current_period_end by the days actually frozen, which would
--                collide with a start_date-based recompute done mid-freeze)
--   cancelled -> membership_cancelled. DECISION: cancelled is a deliberate
--                terminal state (record_manual_payment refuses it for the same
--                reason). A "fix the duration" form must not double as a
--                resurrection button, so there is no p_reactivate flag here;
--                a separate reactivate_membership action is the right place
--                for that, with its own audit and confirmation.
--   If the corrected end date is NOT in the past and status was past_due or
--   expired, the membership returns to 'active' (flag
--   app.membership_status_managed_write, same as freeze/unfreeze/
--   record_manual_payment). "Not in the past" (>= today, not > today) matches
--   mark-overdue, which only flags current_period_end < today.
--   An active membership shortened into the past is left 'active'; the next
--   mark-overdue sweep flips it, exactly as it would for any lapsed row.
--
-- ============================================================================
-- ERROR CODES  (RAISE EXCEPTION message = code; PostgREST: {"message":"<code>"})
-- ============================================================================
--   not_authorized            42501  caller is not owner/front_desk
--   organization_suspended    P0001  caller's org is suspended
--   duration_invalid          P0001  p_duration_months NULL or outside 1..36
--   total_invalid             P0001  p_total_price negative / > 99999999.99
--   membership_not_found      P0001  unknown id, other org, or (front_desk)
--                                    another location — indistinguishable
--   membership_frozen         P0001  unfreeze first
--   membership_cancelled      P0001  cancelled memberships are not editable
--   total_required            P0001  see TOTAL PRICE; HINT carries the
--                                    rate-based suggestion
--   (also: 'update_membership_duration requires an authenticated staff
--    session' when there is no JWT)
--
-- ============================================================================
-- KNOWN LIMITS (by spec: new end = start_date + new duration, start_date kept)
-- ============================================================================
-- The new end date is recomputed from start_date alone. A membership that has
-- since been RENEWED (razorpay-webhook / record_manual_payment extend
-- current_period_end past start_date + duration) or had a FREEZE credited
-- back loses that extension. That is what has_payments = true is for: the UI
-- should warn before calling. The audit row stores old and new end date so the
-- change is reversible by hand.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Audit table
-- ---------------------------------------------------------------------------
CREATE TABLE public.membership_duration_changes (
  id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id     UUID NOT NULL REFERENCES public.organizations(id),
  membership_id       UUID NOT NULL REFERENCES public.memberships(id),
  changed_by          UUID NOT NULL REFERENCES public.users(id),
  old_duration_months INTEGER NOT NULL,
  new_duration_months INTEGER NOT NULL,
  old_period_end      DATE NOT NULL,
  new_period_end      DATE NOT NULL,
  old_total_price     NUMERIC(10,2),
  new_total_price     NUMERIC(10,2),
  old_status          TEXT NOT NULL,
  new_status          TEXT NOT NULL,
  total_was_explicit  BOOLEAN NOT NULL,
  had_payments        BOOLEAN NOT NULL,
  changed_at          TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_membership_duration_changes_membership
  ON public.membership_duration_changes (membership_id, changed_at DESC);

COMMENT ON TABLE public.membership_duration_changes IS
  'Audit trail for update_membership_duration(): one row per correction, '
  'written only by that SECURITY DEFINER function (no authenticated INSERT '
  'grant). Never updated or deleted.';

ALTER TABLE public.membership_duration_changes ENABLE ROW LEVEL SECURITY;

-- Read-only to staff: owner org-wide, front_desk own location (same shape as
-- tenant_isolation_membership_freezes).
CREATE POLICY tenant_isolation_membership_duration_changes ON public.membership_duration_changes
  FOR SELECT
  USING (
    organization_id = (auth.jwt() ->> 'org_id')::uuid
    AND (
      (auth.jwt() ->> 'app_role') = 'owner'
      OR (
        (auth.jwt() ->> 'app_role') = 'front_desk'
        AND EXISTS (
          SELECT 1 FROM public.memberships ms
            JOIN public.members m ON m.id = ms.member_id
           WHERE ms.id = membership_duration_changes.membership_id
             AND m.location_id = (auth.jwt() ->> 'location_id')::uuid
        )
      )
    )
  );

CREATE POLICY org_not_suspended ON public.membership_duration_changes
  AS RESTRICTIVE FOR ALL TO public
  USING (public.current_org_active()) WITH CHECK (public.current_org_active());

GRANT SELECT ON public.membership_duration_changes TO authenticated;
GRANT SELECT ON public.membership_duration_changes TO service_role;

-- ---------------------------------------------------------------------------
-- The RPC
-- ---------------------------------------------------------------------------
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
  has_payments        boolean
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
  v_rate            numeric;
  v_new_end         date;
  v_new_total       numeric;
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

  -- FOR UPDATE: serialise against a concurrent correction / payment / sweep
  -- on the same row so old_* values in the audit row are the ones replaced.
  SELECT ms.member_id, ms.plan_id, ms.status, ms.start_date, ms.current_period_end,
         ms.duration_months, ms.total_price
    INTO v_member_id, v_plan_id, v_status, v_start, v_old_end, v_old_duration, v_old_total
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
  -- active | past_due | expired fall through as correctable.

  v_new_end := (v_start + (p_duration_months || ' months')::interval)::date;

  IF p_total_price IS NOT NULL THEN
    v_new_total := p_total_price;
  ELSE
    SELECT mp.amount INTO v_rate FROM public.membership_plans mp WHERE mp.id = v_plan_id;

    -- Only derive when the stored total is itself the product of the plan rate
    -- and the OLD duration; anything else is custom/stale and must be given.
    IF v_rate IS NULL OR v_old_total IS DISTINCT FROM v_rate * v_old_duration THEN
      RAISE EXCEPTION 'total_required'
        USING DETAIL = 'This membership''s total is not plan rate x duration (negotiated, '
                       'rate changed since signup, or no plan); pass p_total_price.',
              HINT = CASE WHEN v_rate IS NULL THEN NULL
                          ELSE format('plan rate x %s months = %s', p_duration_months, v_rate * p_duration_months) END;
    END IF;
    v_new_total := v_rate * p_duration_months;
  END IF;

  v_new_status := v_status;
  IF v_status IN ('past_due', 'expired') AND v_new_end >= CURRENT_DATE THEN
    v_new_status := 'active';
  END IF;

  -- Money that has actually moved. Pending/failed Razorpay links are not
  -- payments received, so they do not set the flag.
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
         status             = v_new_status
   WHERE ms.id = p_membership_id;

  INSERT INTO public.membership_duration_changes
    (organization_id, membership_id, changed_by,
     old_duration_months, new_duration_months, old_period_end, new_period_end,
     old_total_price, new_total_price, old_status, new_status,
     total_was_explicit, had_payments)
  VALUES
    (v_org, p_membership_id, v_user,
     v_old_duration, p_duration_months, v_old_end, v_new_end,
     v_old_total, v_new_total, v_status, v_new_status,
     p_total_price IS NOT NULL, v_has_payments);

  RETURN QUERY SELECT p_membership_id, p_duration_months, v_new_end, v_new_total,
                      v_new_status, v_has_payments;
END;
$function$;

COMMENT ON FUNCTION public.update_membership_duration(uuid, integer, numeric) IS
  'Owner/front_desk corrects memberships.duration_months after signup: '
  'current_period_end = start_date + new duration, total_price = p_total_price '
  'or plan.amount x new duration (total_required when the stored total is '
  'custom), past_due/expired -> active when the new end is not in the past, '
  'audit row in membership_duration_changes, has_payments flag for the UI. '
  'Refuses frozen and cancelled. SECURITY DEFINER; location/org/role checks '
  're-implemented by hand. See the migration header for the error codes.';

REVOKE ALL ON FUNCTION public.update_membership_duration(uuid, integer, numeric) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.update_membership_duration(uuid, integer, numeric) TO authenticated;
