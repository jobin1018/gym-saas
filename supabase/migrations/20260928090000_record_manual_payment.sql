-- record_manual_payment() — owner/front_desk records a cash/UPI payment
-- taken at the desk for a regular membership renewal: inserts a payments
-- row (status='manual', matching the existing PT-package precedent), and
-- extends the membership exactly the way a real Razorpay payment does.
--
-- ============================================================================
-- WHY THIS DIDN'T ALREADY EXIST
-- ============================================================================
-- 'manual' has been a first-class payments.status since 20260829101000, but
-- the only thing that ever wrote it was an AFTER INSERT trigger on
-- pt_packages (pt_packages_record_payment) — a PT package is "paid" the
-- moment it's sold, so that write only ever needed to react to a row that
-- already existed. There was no equivalent WRITE PATH for a membership
-- renewal paid in cash: only razorpay-webhook (service_role, reconciling a
-- real gateway callback) and the PT trigger ever touched payments at all. A
-- front-desk "member paid in cash" moment had nowhere to go.
--
-- ============================================================================
-- SECURITY DEFINER — required, not a stronger-than-needed default
-- ============================================================================
-- payments' own RLS (tenant_isolation_payments) is OWNER-ONLY — front_desk
-- gets zero rows, by design ("payment history is exactly the kind of
-- financial detail a front-desk PIN should not expose", 20260824140500).
-- `authenticated` also has no INSERT grant on payments AT ALL, not even for
-- owner (confirmed: information_schema.role_table_grants). Every existing
-- authenticated-context write to payments (pt_packages_record_payment) is
-- SECURITY DEFINER for exactly this reason — there is no INVOKER path that
-- could ever write this table from a staff session, freeze_membership-style.
--
-- Because DEFINER bypasses RLS entirely, this function does NOT get
-- front_desk's location scoping "for free" from tenant_isolation_memberships
-- the way unfreeze_membership does — it re-implements that ONE check
-- explicitly (member's location_id vs the caller's own location_id claim),
-- the same shape the RLS policy itself uses. A location mismatch reads as
-- 'membership_not_found', not a distinct "wrong location" error — same
-- existence-masking discipline as staff-pin-reset's cross-org lookups: a
-- front-desk operator has no business learning that a membership exists at
-- a branch that isn't theirs.
--
-- ============================================================================
-- WHAT "PAYABLE" MEANS
-- ============================================================================
-- active | past_due | expired -> payable (early renewal, catching up, or
--   reactivating a lapse are all legitimate reasons cash changed hands).
-- frozen -> refused (membership_frozen). Paying into a paused membership is
--   almost certainly a mistake — unfreeze_membership first, then pay.
-- cancelled -> refused (membership_cancelled). A cancelled membership is a
--   deliberate terminal state (20260905090000's whole point); a stray
--   payment must not silently resurrect it. A genuinely new membership is
--   the correct next step, not this function.
--
-- ============================================================================
-- THE EXTENSION MATH — byte-for-byte razorpay-webhook's own rule
-- ============================================================================
-- extend_from = GREATEST(today, current_period_end) — "so paying early adds
-- the full period rather than truncating the remaining time" (that function's
-- own comment). duration_months drives the length, same column, same
-- `date + (n || ' months')::interval` semantics razorpay-webhook's addMonths()
-- documents itself as replicating (end-of-month clamped: Jan 31 + 1 month ->
-- Feb 28). Two independent payment paths, one shift rule.
--
-- ============================================================================
-- IDEMPOTENT AGAINST A DOUBLE-TAP
-- ============================================================================
-- idempotency_key = 'manual-<membership_id>-<current_period_end-as-called>',
-- same UNIQUE(idempotency_key) column every other payment path already
-- relies on, same 'renewal-<membership>-<date>' SHAPE send-renewal-reminder
-- uses. Two rapid calls for the same membership, before either has advanced
-- current_period_end, collide on the SAME key — the second is detected via
-- the unique_violation and returns the FIRST call's outcome instead of
-- erroring, so a front-desk double-click is a harmless no-op, not a scary
-- failure or (worse) a double-charge/double-extend. A later, genuinely new
-- payment for the same membership naturally gets a different key, because by
-- then current_period_end has moved.
--
-- ============================================================================
-- app.membership_status_managed_write — same flag, same place in the call
-- ============================================================================
-- Set immediately before the status-changing UPDATE, identical to
-- freeze_membership / unfreeze_membership (20260905090000's guard trigger
-- only allows a direct 'cancelled' transition otherwise).
-- ============================================================================

-- No column exists yet to record cash vs UPI vs card. Nullable: every other
-- payment path (razorpay, the PT trigger) leaves it NULL — this is not
-- meaningful for a gateway-reconciled row.
ALTER TABLE public.payments ADD COLUMN method text;
ALTER TABLE public.payments ADD CONSTRAINT payments_method_check
  CHECK (method IS NULL OR method IN ('cash', 'upi', 'card', 'bank_transfer', 'other'));

COMMENT ON COLUMN public.payments.method IS
  'How a manual (desk-recorded) payment was taken: cash | upi | card | '
  'bank_transfer | other. NULL for every gateway-reconciled or '
  'trigger-recorded row (razorpay, PT packages) — not applicable there.';

CREATE FUNCTION public.record_manual_payment(
  p_membership_id uuid,
  p_amount numeric,
  p_method text
)
RETURNS TABLE(
  payment_id          uuid,
  membership_id       uuid,
  amount              numeric,
  method              text,
  current_period_end  date,
  status              text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_org             uuid := (auth.jwt() ->> 'org_id')::uuid;
  v_role            text := (auth.jwt() ->> 'app_role');
  v_caller_location uuid;
  v_org_id          uuid;
  v_member_id       uuid;
  v_status          text;
  v_duration        integer;
  v_period_end      date;
  v_member_location uuid;
  v_extend_from     date;
  v_new_end         date;
  v_idem_key        text;
  v_payment_id      uuid;
BEGIN
  IF v_org IS NULL OR (auth.jwt() ->> 'user_id') IS NULL THEN
    RAISE EXCEPTION 'record_manual_payment requires an authenticated staff session';
  END IF;

  IF v_role NOT IN ('owner', 'front_desk') THEN
    RAISE EXCEPTION 'not_authorized' USING errcode = '42501';
  END IF;

  IF NOT public.current_org_active() THEN
    RAISE EXCEPTION 'organization_suspended' USING errcode = 'P0001';
  END IF;

  IF p_amount IS NULL OR p_amount <= 0 THEN
    RAISE EXCEPTION 'amount_invalid';
  END IF;

  IF p_method IS NULL OR p_method NOT IN ('cash', 'upi', 'card', 'bank_transfer', 'other') THEN
    RAISE EXCEPTION 'method_invalid';
  END IF;

  SELECT m.organization_id, m.member_id, m.status, m.duration_months, m.current_period_end
    INTO v_org_id, v_member_id, v_status, v_duration, v_period_end
    FROM public.memberships m
   WHERE m.id = p_membership_id;

  IF NOT FOUND OR v_org_id <> v_org THEN
    RAISE EXCEPTION 'membership_not_found';
  END IF;

  -- front_desk location scoping, done by hand (SECURITY DEFINER bypasses
  -- tenant_isolation_memberships' own version of this same check) — masked
  -- as membership_not_found, not a distinct authorization error.
  IF v_role = 'front_desk' THEN
    v_caller_location := (auth.jwt() ->> 'location_id')::uuid;
    SELECT mm.location_id INTO v_member_location
      FROM public.members mm WHERE mm.id = v_member_id;
    IF v_caller_location IS NULL OR v_member_location IS DISTINCT FROM v_caller_location THEN
      RAISE EXCEPTION 'membership_not_found';
    END IF;
  END IF;

  IF v_status = 'frozen' THEN
    RAISE EXCEPTION 'membership_frozen';
  ELSIF v_status = 'cancelled' THEN
    RAISE EXCEPTION 'membership_cancelled';
  END IF;
  -- active | past_due | expired all fall through as payable.

  v_extend_from := GREATEST(CURRENT_DATE, v_period_end);
  v_new_end := (v_extend_from + (v_duration || ' months')::interval)::date;
  v_idem_key := 'manual-' || p_membership_id::text || '-' || v_period_end::text;

  BEGIN
    INSERT INTO public.payments
      (organization_id, membership_id, amount, provider, method, status, idempotency_key, reconciled_at)
    VALUES
      (v_org, p_membership_id, p_amount, 'manual', p_method, 'manual', v_idem_key, now())
    RETURNING id INTO v_payment_id;
  EXCEPTION WHEN unique_violation THEN
    -- Double-tap: this exact (membership, pre-update period_end) payment was
    -- already recorded. Return its outcome rather than erroring — a repeat
    -- click must be a harmless no-op, never a double-extend.
    SELECT p.id INTO v_payment_id
      FROM public.payments p WHERE p.idempotency_key = v_idem_key;
    RETURN QUERY
      SELECT v_payment_id, p_membership_id, p_amount, p_method, m.current_period_end, m.status
        FROM public.memberships m WHERE m.id = p_membership_id;
    RETURN;
  END;

  PERFORM set_config('app.membership_status_managed_write', 'on', true);

  UPDATE public.memberships m
     SET status = 'active',
         current_period_end = v_new_end
   WHERE m.id = p_membership_id
     AND m.status NOT IN ('frozen', 'cancelled')
   RETURNING m.current_period_end INTO v_new_end;

  IF NOT FOUND THEN
    -- Only reachable via a concurrent status change between the check above
    -- and this UPDATE (frozen/cancelled mid-flight) — raising here rolls
    -- back the INSERT too, so no orphaned payment row survives.
    RAISE EXCEPTION 'membership_not_active';
  END IF;

  RETURN QUERY SELECT v_payment_id, p_membership_id, p_amount, p_method, v_new_end, 'active'::text;
END;
$function$;

COMMENT ON FUNCTION public.record_manual_payment(uuid, numeric, text) IS
  'Owner/front_desk records a cash/UPI/card/bank_transfer payment taken at '
  'the desk for a membership renewal: inserts payments (status=''manual'', '
  'method=p_method), extends current_period_end by the membership''s own '
  'duration_months from GREATEST(today, current_period_end), sets status '
  'active. SECURITY DEFINER (payments has no authenticated INSERT grant at '
  'all) — front_desk location scoping and the org-suspended/frozen/'
  'cancelled gates are re-implemented explicitly since DEFINER bypasses '
  'RLS. Idempotent per (membership_id, current_period_end-at-call-time): a '
  'repeat call before the period advances returns the original result '
  'instead of erroring.';

REVOKE ALL ON FUNCTION public.record_manual_payment(uuid, numeric, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.record_manual_payment(uuid, numeric, text) TO authenticated;
