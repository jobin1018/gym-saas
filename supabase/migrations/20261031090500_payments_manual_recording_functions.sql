-- Manual payment recording, part 2 of 2: the functions.
--   * payment_covering_collected(payment_id)  — "is this period already paid?"
--   * record_manual_payment(...)              — replaces the 3-arg version from
--                                               20260928090000 (amended, not
--                                               duplicated: same name, same job)
--   * void_payment(payment_id, reason)        — owner-only undo
--
-- ============================================================================
-- record_manual_payment(p_membership_id, p_amount, p_method,
--                       p_reference DEFAULT NULL, p_received_at DEFAULT today,
--                       p_note DEFAULT NULL)
-- ============================================================================
-- Who: owner, or front_desk at the member's own location (a wrong location reads
-- as membership_not_found, same existence-masking as before). Suspended orgs
-- are refused.
-- Amount: must EQUAL the membership's total_price (falling back to
-- membership_renewal_amount() for a legacy row with no total). Partial payments
-- and instalments are out of scope: amount_mismatch says so and quotes the
-- expected figure.
-- received_at: not in the future and at most 7 days back.
-- Effect (one transaction):
--   1. insert the payment: status 'manual', provider 'manual', payment_method,
--      reference, note, received_at, recorded_by, covers_from = GREATEST(today,
--      current_period_end), covers_to = covers_from + duration months;
--   2. void any PENDING payment for this membership whose coverage overlaps
--      (or is unknown) — the Razorpay link the member may still pay. The link
--      itself stays live at Razorpay; if it is paid anyway, razorpay-webhook
--      records the money as refund_due and does not extend again;
--   3. extend current_period_end to covers_to and set status active through
--      app.membership_status_managed_write — the same rule razorpay-webhook uses.
-- IDEMPOTENCY: the membership is read WITHOUT FOR UPDATE on purpose. Two
-- simultaneous taps must both see the SAME period end, build the SAME key and
-- collide on payments.idempotency_key (the serialiser); a row lock would make
-- the second tap wait, then see the advanced end date and record a 2nd payment.
-- Idempotent against a double tap: key manual-<membership>-<period end at call
-- time>; a repeat before the period advances returns the first call's result.
--
-- Errors (message = code):
--   not_authorized (42501)      caller is not owner/front_desk
--   organization_suspended      org suspended
--   amount_invalid              p_amount null or <= 0
--   method_invalid              not cash | upi | card | bank_transfer
--   received_at_invalid         in the future, or more than 7 days ago
--   membership_not_found        unknown / other org / front_desk other location
--   membership_frozen           unfreeze first
--   membership_cancelled        cancelled is terminal
--   amount_mismatch             p_amount <> the membership's total (DETAIL has it)
--   membership_not_active       concurrent status change mid-call (rolls back)
--
-- ============================================================================
-- void_payment(p_payment_id, p_reason)  — OWNER ONLY
-- ============================================================================
-- Marks a manual payment void and records who/when/why. It does NOT touch the
-- membership: dates and status stay exactly as the payment left them. It returns
-- what the owner needs to put them right:
--   previous_period_end  the end date before this payment extended it (parsed
--                        from the payment's idempotency key)
--   covers_from/covers_to, months_added, current_period_end, start_date,
--   duration_months
--   can_restore_with_update_duration / restore_duration_months — TRUE when
--     start_date + duration_months equals previous_period_end, i.e. the
--     membership had never been renewed before this payment; then calling
--     update_membership_duration(membership, restore_duration_months) puts the
--     end date back. If it had been renewed earlier, update_membership_duration
--     (which recomputes the end from start_date alone) CANNOT restore the date
--     and advice says so.
-- Errors: not_authorized (42501, anyone but owner), organization_suspended,
--   reason_required, payment_not_found (also other orgs), payment_already_void,
--   payment_not_voidable (only desk-recorded 'manual' payments; a captured
--   Razorpay payment is refunded at Razorpay, not voided here).
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Is the period this payment covers already covered by a collected payment?
-- Returns the id of that other payment, or NULL. Membership payments only.
-- Coverage is half-open [covers_from, covers_to); overlap, not equality, so a
-- link created late still collides with a desk payment made early.
-- Rows that predate the covers_* columns fall back to the period their
-- idempotency key (renewal-<membership>-<period end>) names.
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.payment_covering_collected(p_payment_id uuid)
RETURNS uuid
LANGUAGE plpgsql
STABLE
SET search_path = public, pg_temp
AS $$
DECLARE
  r        public.payments%ROWTYPE;
  v_from   date;
  v_to     date;
  v_dur    integer;
  v_keydt  date;
  v_other  uuid;
BEGIN
  SELECT * INTO r FROM public.payments WHERE id = p_payment_id;
  IF NOT FOUND OR r.membership_id IS NULL THEN
    RETURN NULL;
  END IF;

  v_from := r.covers_from;
  v_to   := r.covers_to;

  IF v_from IS NULL THEN
    BEGIN
      v_keydt := substring(r.idempotency_key FROM '(\d{4}-\d{2}-\d{2})$')::date;
    EXCEPTION WHEN others THEN
      v_keydt := NULL;
    END;
    SELECT ms.duration_months INTO v_dur FROM public.memberships ms WHERE ms.id = r.membership_id;
    IF v_keydt IS NULL OR v_dur IS NULL THEN
      RETURN NULL;
    END IF;
    v_from := GREATEST(r.created_at::date, v_keydt);
    v_to   := (v_from + (v_dur || ' months')::interval)::date;
  END IF;

  SELECT p.id INTO v_other
    FROM public.payments p
   WHERE p.membership_id = r.membership_id
     AND p.id <> r.id
     AND public.payment_is_collected(p.status)
     AND p.covers_from IS NOT NULL
     AND p.covers_from < v_to
     AND v_from < p.covers_to
   ORDER BY p.created_at
   LIMIT 1;

  RETURN v_other;
END;
$$;

COMMENT ON FUNCTION public.payment_covering_collected(uuid) IS
  'Id of an already-collected payment (success/manual) whose coverage overlaps '
  'this membership payment''s, else NULL. razorpay-webhook calls it before '
  'extending: a hit means the period is already paid, so the money is recorded '
  'as refund_due and the membership is NOT extended again. service_role only.';

REVOKE ALL ON FUNCTION public.payment_covering_collected(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.payment_covering_collected(uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- record_manual_payment v2
-- ---------------------------------------------------------------------------
DROP FUNCTION public.record_manual_payment(uuid, numeric, text);

CREATE FUNCTION public.record_manual_payment(
  p_membership_id uuid,
  p_amount        numeric,
  p_method        text,
  p_reference     text DEFAULT NULL,
  p_received_at   date DEFAULT CURRENT_DATE,
  p_note          text DEFAULT NULL
)
RETURNS TABLE(
  payment_id          uuid,
  membership_id       uuid,
  amount              numeric,
  payment_method      text,
  reference           text,
  received_at         date,
  covers_from         date,
  covers_to           date,
  current_period_end  date,
  status              text,
  voided_pending      integer
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
  v_status          text;
  v_duration        integer;
  v_period_end      date;
  v_total           numeric;
  v_expected        numeric;
  v_received        date := COALESCE(p_received_at, CURRENT_DATE);
  v_ref             text := NULLIF(btrim(COALESCE(p_reference, '')), '');
  v_note            text := NULLIF(btrim(COALESCE(p_note, '')), '');
  v_covers_from     date;
  v_covers_to       date;
  v_idem_key        text;
  v_payment_id      uuid;
  v_voided          integer;
  v_new_end         date;
BEGIN
  IF v_org IS NULL OR v_user IS NULL THEN
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

  IF p_method IS NULL OR p_method NOT IN ('cash', 'upi', 'card', 'bank_transfer') THEN
    RAISE EXCEPTION 'method_invalid' USING DETAIL = 'cash | upi | card | bank_transfer';
  END IF;

  IF v_received > CURRENT_DATE OR v_received < CURRENT_DATE - 7 THEN
    RAISE EXCEPTION 'received_at_invalid'
      USING DETAIL = 'received_at cannot be in the future or more than 7 days ago';
  END IF;

  SELECT ms.member_id, ms.status, ms.duration_months, ms.current_period_end, ms.total_price
    INTO v_member_id, v_status, v_duration, v_period_end, v_total
    FROM public.memberships ms
   WHERE ms.id = p_membership_id
     AND ms.organization_id = v_org;  -- NO FOR UPDATE on purpose: see IDEMPOTENCY note

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
    RAISE EXCEPTION 'membership_frozen';
  ELSIF v_status = 'cancelled' THEN
    RAISE EXCEPTION 'membership_cancelled';
  END IF;

  v_expected := COALESCE(v_total, public.membership_renewal_amount(p_membership_id));
  IF p_amount IS DISTINCT FROM v_expected THEN
    RAISE EXCEPTION 'amount_mismatch'
      USING DETAIL = format('Expected %s, the full total for this membership. Partial payments and instalments are not supported.', v_expected),
            HINT   = v_expected::text;
  END IF;

  v_covers_from := GREATEST(CURRENT_DATE, v_period_end);
  v_covers_to   := (v_covers_from + (v_duration || ' months')::interval)::date;
  v_idem_key    := 'manual-' || p_membership_id::text || '-' || v_period_end::text;

  BEGIN
    INSERT INTO public.payments
      (organization_id, membership_id, amount, provider, payment_method, reference, note,
       status, idempotency_key, reconciled_at, received_at, recorded_by, covers_from, covers_to)
    VALUES
      (v_org, p_membership_id, p_amount, 'manual', p_method, v_ref, v_note,
       'manual', v_idem_key, now(), v_received, v_user, v_covers_from, v_covers_to)
    RETURNING id INTO v_payment_id;
  EXCEPTION WHEN unique_violation THEN
    -- Double-tap: the same payment for the same pre-update period was already
    -- recorded. Return that outcome; never extend twice.
    SELECT p.id INTO v_payment_id FROM public.payments p WHERE p.idempotency_key = v_idem_key;
    RETURN QUERY
      SELECT p.id, p.membership_id, p.amount, p.payment_method, p.reference, p.received_at,
             p.covers_from, p.covers_to, ms.current_period_end, ms.status, 0
        FROM public.payments p
        JOIN public.memberships ms ON ms.id = p.membership_id
       WHERE p.id = v_payment_id;
    RETURN;
  END;

  -- Supersede pending links for this period (coverage overlaps, or unknown).
  UPDATE public.payments p
     SET status      = 'void',
         voided_by   = v_user,
         voided_at   = now(),
         void_reason = 'Superseded by manual payment ' || v_payment_id::text
   WHERE p.membership_id = p_membership_id
     AND p.status = 'pending'
     AND (p.covers_from IS NULL
          OR (p.covers_from < v_covers_to AND v_covers_from < p.covers_to));
  GET DIAGNOSTICS v_voided = ROW_COUNT;

  PERFORM set_config('app.membership_status_managed_write', 'on', true);

  UPDATE public.memberships ms
     SET status = 'active',
         current_period_end = v_covers_to
   WHERE ms.id = p_membership_id
     AND ms.status NOT IN ('frozen', 'cancelled')
   RETURNING ms.current_period_end INTO v_new_end;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'membership_not_active';
  END IF;

  RETURN QUERY SELECT v_payment_id, p_membership_id, p_amount, p_method, v_ref, v_received,
                      v_covers_from, v_covers_to, v_new_end, 'active'::text, v_voided;
END;
$function$;

COMMENT ON FUNCTION public.record_manual_payment(uuid, numeric, text, text, date, text) IS
  'Owner/front_desk records a desk payment for the membership''s FULL total '
  '(amount_mismatch otherwise). Inserts payments (status manual, payment_method, '
  'reference, note, received_at, recorded_by, covers_from/covers_to), voids '
  'overlapping pending links, extends current_period_end from GREATEST(today, '
  'current end) by duration_months and sets status active via the managed-write '
  'flag. Idempotent per (membership, period end at call time). SECURITY DEFINER; '
  'location/org/role/suspended/frozen/cancelled checks re-implemented by hand.';

REVOKE ALL ON FUNCTION public.record_manual_payment(uuid, numeric, text, text, date, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.record_manual_payment(uuid, numeric, text, text, date, text) TO authenticated;

-- ---------------------------------------------------------------------------
-- void_payment
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.void_payment(p_payment_id uuid, p_reason text)
RETURNS TABLE(
  payment_id                       uuid,
  membership_id                    uuid,
  status                           text,
  amount                           numeric,
  voided_at                        timestamptz,
  previous_period_end              date,
  covers_from                      date,
  covers_to                        date,
  months_added                     integer,
  current_period_end               date,
  start_date                       date,
  duration_months                  integer,
  can_restore_with_update_duration boolean,
  restore_duration_months          integer,
  advice                           text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_org        uuid := (auth.jwt() ->> 'org_id')::uuid;
  v_user       uuid := (auth.jwt() ->> 'user_id')::uuid;
  v_role       text := (auth.jwt() ->> 'app_role');
  v_reason     text := NULLIF(btrim(COALESCE(p_reason, '')), '');
  r            public.payments%ROWTYPE;
  v_prev_end   date;
  v_start      date;
  v_duration   integer;
  v_cur_end    date;
  v_months     integer;
  v_can        boolean;
  v_voided_at  timestamptz := now();
BEGIN
  IF v_org IS NULL OR v_user IS NULL THEN
    RAISE EXCEPTION 'void_payment requires an authenticated staff session';
  END IF;

  IF v_role <> 'owner' THEN
    RAISE EXCEPTION 'not_authorized' USING errcode = '42501';
  END IF;

  IF NOT public.current_org_active() THEN
    RAISE EXCEPTION 'organization_suspended' USING errcode = 'P0001';
  END IF;

  IF v_reason IS NULL THEN
    RAISE EXCEPTION 'reason_required';
  END IF;

  SELECT * INTO r FROM public.payments p
   WHERE p.id = p_payment_id AND p.organization_id = v_org
     FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'payment_not_found';
  END IF;

  IF r.status = 'void' THEN
    RAISE EXCEPTION 'payment_already_void';
  ELSIF r.status <> 'manual' THEN
    RAISE EXCEPTION 'payment_not_voidable'
      USING DETAIL = 'Only desk-recorded (manual) payments can be voided; a captured Razorpay payment is refunded at Razorpay.';
  END IF;

  UPDATE public.payments p
     SET status = 'void', voided_by = v_user, voided_at = v_voided_at, void_reason = v_reason
   WHERE p.id = p_payment_id;

  -- NOTE: the membership is deliberately NOT touched.
  IF r.membership_id IS NOT NULL THEN
    SELECT ms.start_date, ms.duration_months, ms.current_period_end
      INTO v_start, v_duration, v_cur_end
      FROM public.memberships ms WHERE ms.id = r.membership_id;
    BEGIN
      v_prev_end := substring(r.idempotency_key FROM '(\d{4}-\d{2}-\d{2})$')::date;
    EXCEPTION WHEN others THEN
      v_prev_end := NULL;
    END;
    v_months := CASE WHEN r.covers_from IS NOT NULL
                     THEN (EXTRACT(YEAR FROM age(r.covers_to, r.covers_from)) * 12
                           + EXTRACT(MONTH FROM age(r.covers_to, r.covers_from)))::integer
                END;
    v_can := v_prev_end IS NOT NULL
             AND (v_start + (v_duration || ' months')::interval)::date = v_prev_end;
  END IF;

  RETURN QUERY SELECT
    p_payment_id, r.membership_id, 'void'::text, r.amount, v_voided_at,
    v_prev_end, r.covers_from, r.covers_to, v_months, v_cur_end, v_start, v_duration,
    COALESCE(v_can, false),
    CASE WHEN v_can THEN v_duration END,
    CASE
      WHEN r.membership_id IS NULL THEN 'Payment voided; it was not tied to a membership.'
      WHEN v_can THEN format(
        'Payment voided; the membership still ends %s. To put it back to %s call update_membership_duration(%s, %s).',
        v_cur_end, v_prev_end, r.membership_id, v_duration)
      ELSE format(
        'Payment voided; the membership still ends %s (it ended %s before this payment). update_membership_duration recomputes the end from start_date + duration and cannot restore this date because the membership was renewed before; correct it by hand.',
        v_cur_end, COALESCE(v_prev_end::text, 'unknown'))
    END;
END;
$function$;

COMMENT ON FUNCTION public.void_payment(uuid, text) IS
  'Owner-only. Voids a desk-recorded (manual) payment with a mandatory reason; '
  'records voided_by/voided_at/void_reason. Does NOT change the membership''s '
  'dates or status — returns previous_period_end, coverage, and whether '
  'update_membership_duration can restore the old end date. Revenue and the '
  'daily brief drop the payment immediately (payment_is_collected).';

REVOKE ALL ON FUNCTION public.void_payment(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.void_payment(uuid, text) TO authenticated;
