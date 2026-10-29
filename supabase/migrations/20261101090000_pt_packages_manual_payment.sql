-- PT packages through the manual payment flow: a package sale no longer records
-- collected money; the desk records it with record_manual_payment, like a
-- membership. No instalments.
--
-- ============================================================================
-- DECISIONS (agreed)
-- ============================================================================
--  1. No instalments. record_manual_payment accepts p_pt_package_id as an
--     alternative to p_membership_id; the amount must EQUAL the package price
--     (amount_mismatch otherwise).
--  2. An unpaid package is fully usable: nothing here touches sessions, notes
--     or log_session. is_paid is information only.
--  3. At sale NO payment row is created (pt_packages_record_payment() and its
--     trigger are dropped). Considered and rejected: a 'pending' row at sale.
--     razorpay-webhook matches a PT payment by provider_payment_id, link id,
--     notes.idempotency_key or notes.pt_package_id + status 'pending'; a
--     sale-time pending row would give the webhook something to match, but the
--     Razorpay PT checkout that doesn't exist yet creates its own pending row
--     (20260829101000's own note), and a stray pending row at every sale would
--     (a) have to be voided by every desk payment, (b) clutter the ledger with
--     rows that are not payments, and (c) make "pending" mean "owed" for PT and
--     "a live payment link" for memberships. "Unpaid" is simply "no collected
--     payment", derivable without a row.
--  4. Existing PT rows are untouched (no UPDATE/DELETE of any payments row).
--     Packages sold before this migration keep their collected 'manual' payment
--     and therefore read is_paid = true.
--  5. The PT exemption in payments_manual_method_required is removed:
--     provider = 'manual' now needs payment_method for PT rows too. The check is
--     NOT VALID so the legacy PT rows (method NULL) are not rejected, and it
--     also lets a row through once status = 'void', so an owner CAN still void a
--     legacy method-less PT payment (an UPDATE re-checks the row).
--  6. Same idempotency, location scoping, suspended-org refusal and void rules
--     as memberships.
--
-- ============================================================================
-- record_manual_payment(p_membership_id, p_amount, p_method, p_reference,
--                       p_received_at, p_note, p_pt_package_id)
-- ============================================================================
-- Exactly ONE of p_membership_id / p_pt_package_id (else subject_invalid). The
-- first three parameters now default to NULL purely so a PT call can omit
-- p_membership_id; positional order for existing membership callers is
-- unchanged (p_pt_package_id is appended last).
-- PT branch:
--   who      owner; front_desk only for a member at their own location (a
--            wrong location reads as pt_package_not_found)
--   refuses  suspended orgs; cancelled packages (pt_package_cancelled)
--   amount   must equal pt_packages.price exactly (amount_mismatch)
--   paid     a package that already has a collected payment -> package_already_paid
--            (DETAIL names the payment). A price-0 comp package owes nothing.
--   effect   inserts the payment (status manual, provider manual, payment_method,
--            reference, note, received_at, recorded_by; no coverage period) and
--            voids any pending payment for the package. No package status change.
--   idempotency key manual-pt-<package>-<n>, n = payments of provider 'manual'
--            already on the package. Two simultaneous taps compute the same n and
--            collide on payments.idempotency_key (no row lock, same reasoning as
--            memberships), so the second returns the first. After a void, n has
--            grown, so the package can be paid again.
-- New error codes (PT): pt_package_not_found, pt_package_cancelled,
--   package_already_paid, subject_invalid. All earlier codes apply unchanged
--   (not_authorized, organization_suspended, amount_invalid, method_invalid,
--   received_at_invalid, amount_mismatch).
-- Return gains pt_package_id; for a PT payment membership_id, covers_*,
-- current_period_end are NULL and status is the package's status.
--
-- void_payment: works on manual PT payments too (same owner-only, reason,
-- already-void and not-voidable rules). Voiding makes the package unpaid again;
-- sessions and notes are unaffected. Return gains pt_package_id.
--
-- razorpay-webhook: payment_covering_collected() now also answers for PT
-- payments - any OTHER collected payment on the same package means it is
-- already paid, so a Razorpay payment for it is recorded as refund_due.
--
-- ============================================================================
-- PAID / UNPAID
-- ============================================================================
--   is_paid = price = 0 (comp) OR a collected payment (payment_is_collected)
--             exists for the package.
--   v_pt_packages_attention gains is_paid (appended). It does NOT add 'unpaid'
--   as an attention reason: the daily brief's pt_alert_count counts that view's
--   rows, and silently changing that figure is a separate decision.
--   NEW v_pt_package_payment_status (pt_package_id, organization_id, member_id,
--   price, is_paid) so the sales desk can show a paid badge: owner org-wide,
--   front_desk their own location, same rule as v_payments_ledger. Coaches get
--   no payment information.
-- ============================================================================

-- 1. Stop recording collected money at sale -----------------------------------
DROP TRIGGER trg_pt_packages_record_payment ON public.pt_packages;
DROP FUNCTION public.pt_packages_record_payment();

-- 5. Remove the PT exemption ---------------------------------------------------
ALTER TABLE public.payments DROP CONSTRAINT payments_manual_method_required;
ALTER TABLE public.payments
  ADD CONSTRAINT payments_manual_method_required
    CHECK (provider <> 'manual' OR payment_method IS NOT NULL OR status = 'void') NOT VALID;

-- Coverage check: PT payments too ---------------------------------------------
CREATE OR REPLACE FUNCTION public.payment_covering_collected(p_payment_id uuid)
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
  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  -- PT package: no periods and no instalments - any other collected payment on
  -- the package means it is already paid.
  IF r.pt_package_id IS NOT NULL THEN
    SELECT p.id INTO v_other
      FROM public.payments p
     WHERE p.pt_package_id = r.pt_package_id
       AND p.id <> r.id
       AND public.payment_is_collected(p.status)
     ORDER BY p.created_at
     LIMIT 1;
    RETURN v_other;
  END IF;

  IF r.membership_id IS NULL THEN
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

-- record_manual_payment: membership OR PT package -----------------------------
DROP FUNCTION public.record_manual_payment(uuid, numeric, text, text, date, text);

CREATE FUNCTION public.record_manual_payment(
  p_membership_id uuid    DEFAULT NULL,
  p_amount        numeric DEFAULT NULL,
  p_method        text    DEFAULT NULL,
  p_reference     text    DEFAULT NULL,
  p_received_at   date    DEFAULT CURRENT_DATE,
  p_note          text    DEFAULT NULL,
  p_pt_package_id uuid    DEFAULT NULL
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
  voided_pending      integer,
  pt_package_id       uuid
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
  v_price           numeric;
  v_expected        numeric;
  v_received        date := COALESCE(p_received_at, CURRENT_DATE);
  v_ref             text := NULLIF(btrim(COALESCE(p_reference, '')), '');
  v_note            text := NULLIF(btrim(COALESCE(p_note, '')), '');
  v_covers_from     date;
  v_covers_to       date;
  v_idem_key        text;
  v_payment_id      uuid;
  v_existing        uuid;
  v_n               integer;
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

  IF (p_membership_id IS NULL) = (p_pt_package_id IS NULL) THEN
    RAISE EXCEPTION 'subject_invalid'
      USING DETAIL = 'Pass exactly one of p_membership_id / p_pt_package_id.';
  END IF;

  -- ======================= PT PACKAGE =======================
  IF p_pt_package_id IS NOT NULL THEN
    SELECT pk.member_id, pk.status, pk.price
      INTO v_member_id, v_status, v_price
      FROM public.pt_packages pk
     WHERE pk.id = p_pt_package_id
       AND pk.organization_id = v_org;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'pt_package_not_found';
    END IF;

    IF v_role = 'front_desk' THEN
      v_caller_location := (auth.jwt() ->> 'location_id')::uuid;
      SELECT mm.location_id INTO v_member_location
        FROM public.members mm WHERE mm.id = v_member_id;
      IF v_caller_location IS NULL OR v_member_location IS DISTINCT FROM v_caller_location THEN
        RAISE EXCEPTION 'pt_package_not_found';
      END IF;
    END IF;

    IF v_status = 'cancelled' THEN
      RAISE EXCEPTION 'pt_package_cancelled';
    END IF;

    IF p_amount IS DISTINCT FROM v_price THEN
      RAISE EXCEPTION 'amount_mismatch'
        USING DETAIL = format('Expected %s, the full price of this package. Partial payments and instalments are not supported.', v_price),
              HINT   = v_price::text;
    END IF;

    SELECT p.id INTO v_existing
      FROM public.payments p
     WHERE p.pt_package_id = p_pt_package_id
       AND public.payment_is_collected(p.status)
     LIMIT 1;
    IF v_existing IS NOT NULL THEN
      RAISE EXCEPTION 'package_already_paid'
        USING DETAIL = 'Already paid by payment ' || v_existing::text,
              HINT   = v_existing::text;
    END IF;

    SELECT count(*) + 1 INTO v_n
      FROM public.payments p
     WHERE p.pt_package_id = p_pt_package_id AND p.provider = 'manual';
    v_idem_key := 'manual-pt-' || p_pt_package_id::text || '-' || v_n::text;

    BEGIN
      INSERT INTO public.payments
        (organization_id, membership_id, pt_package_id, amount, provider, payment_method,
         reference, note, status, idempotency_key, reconciled_at, received_at, recorded_by)
      VALUES
        (v_org, NULL, p_pt_package_id, p_amount, 'manual', p_method,
         v_ref, v_note, 'manual', v_idem_key, now(), v_received, v_user)
      RETURNING id INTO v_payment_id;
    EXCEPTION WHEN unique_violation THEN
      SELECT p.id INTO v_payment_id FROM public.payments p WHERE p.idempotency_key = v_idem_key;
      RETURN QUERY
        SELECT p.id, p.membership_id, p.amount, p.payment_method, p.reference, p.received_at,
               p.covers_from, p.covers_to, NULL::date, v_status, 0, p.pt_package_id
          FROM public.payments p
         WHERE p.id = v_payment_id;
      RETURN;
    END;

    UPDATE public.payments p
       SET status      = 'void',
           voided_by   = v_user,
           voided_at   = now(),
           void_reason = 'Superseded by manual payment ' || v_payment_id::text
     WHERE p.pt_package_id = p_pt_package_id
       AND p.status = 'pending';
    GET DIAGNOSTICS v_voided = ROW_COUNT;

    RETURN QUERY SELECT v_payment_id, NULL::uuid, p_amount, p_method, v_ref, v_received,
                        NULL::date, NULL::date, NULL::date, v_status, v_voided, p_pt_package_id;
    RETURN;
  END IF;

  -- ======================= MEMBERSHIP (unchanged) =======================
  SELECT ms.member_id, ms.status, ms.duration_months, ms.current_period_end, ms.total_price
    INTO v_member_id, v_status, v_duration, v_period_end, v_total
    FROM public.memberships ms
   WHERE ms.id = p_membership_id
     AND ms.organization_id = v_org;  -- NO FOR UPDATE on purpose (see 20261031090500)

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
    SELECT p.id INTO v_payment_id FROM public.payments p WHERE p.idempotency_key = v_idem_key;
    RETURN QUERY
      SELECT p.id, p.membership_id, p.amount, p.payment_method, p.reference, p.received_at,
             p.covers_from, p.covers_to, ms.current_period_end, ms.status, 0, p.pt_package_id
        FROM public.payments p
        JOIN public.memberships ms ON ms.id = p.membership_id
       WHERE p.id = v_payment_id;
    RETURN;
  END;

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
                      v_covers_from, v_covers_to, v_new_end, 'active'::text, v_voided, NULL::uuid;
END;
$function$;

COMMENT ON FUNCTION public.record_manual_payment(uuid, numeric, text, text, date, text, uuid) IS
  'Owner/front_desk records a desk payment for a membership (p_membership_id) OR '
  'a PT package (p_pt_package_id) - exactly one. Full total/price only '
  '(amount_mismatch). Membership: coverage, supersedes overlapping pending '
  'links, extends current_period_end, sets status active. PT package: no '
  'instalments, package_already_paid if it already has a collected payment, '
  'supersedes pending PT payments, never changes the package. Idempotent '
  '(membership: per period end; PT: per package + manual-payment count). '
  'SECURITY DEFINER; role/org/location/suspended checks re-implemented by hand.';

REVOKE ALL ON FUNCTION public.record_manual_payment(uuid, numeric, text, text, date, text, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.record_manual_payment(uuid, numeric, text, text, date, text, uuid) TO authenticated;

-- void_payment: PT payments too --------------------------------------------------
DROP FUNCTION public.void_payment(uuid, text);

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
  advice                           text,
  pt_package_id                    uuid
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
      WHEN r.pt_package_id IS NOT NULL THEN
        'Payment voided; the PT package is unpaid again. Sessions and notes are unaffected.'
      WHEN r.membership_id IS NULL THEN 'Payment voided; it was not tied to a membership.'
      WHEN v_can THEN format(
        'Payment voided; the membership still ends %s. To put it back to %s call update_membership_duration(%s, %s).',
        v_cur_end, v_prev_end, r.membership_id, v_duration)
      ELSE format(
        'Payment voided; the membership still ends %s (it ended %s before this payment). update_membership_duration recomputes the end from start_date + duration and cannot restore this date because the membership was renewed before; correct it by hand.',
        v_cur_end, COALESCE(v_prev_end::text, 'unknown'))
    END,
    r.pt_package_id;
END;
$function$;

COMMENT ON FUNCTION public.void_payment(uuid, text) IS
  'Owner-only. Voids a desk-recorded (manual) payment, membership or PT package, '
  'with a mandatory reason. Never changes a membership''s dates/status (returns '
  'what is needed to correct them) nor a PT package (it simply becomes unpaid).';

REVOKE ALL ON FUNCTION public.void_payment(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.void_payment(uuid, text) TO authenticated;

-- Paid / unpaid ------------------------------------------------------------------
CREATE OR REPLACE VIEW public.v_pt_packages_attention AS
 SELECT p.id,
    p.organization_id,
    p.member_id,
    p.coach_id,
    m.name AS member_name,
    m.phone AS member_phone,
    u.name AS coach_name,
    p.goal,
    p.sessions_purchased,
    p.sessions_used,
    p.sessions_purchased - p.sessions_used AS sessions_remaining,
    p.start_date,
    (p.start_date + make_interval(months => p.duration_months))::date AS expected_end_date,
    (p.start_date + make_interval(months => p.duration_months))::date - CURRENT_DATE AS days_until_end,
    (p.sessions_purchased - p.sessions_used) <= 2 AS low_sessions,
    ((p.start_date + make_interval(months => p.duration_months))::date - CURRENT_DATE) <= 7 AS expiring_soon,
    (p.price = 0 OR EXISTS (
       SELECT 1 FROM public.payments pay
        WHERE pay.pt_package_id = p.id AND public.payment_is_collected(pay.status)
    )) AS is_paid
   FROM pt_packages p
     JOIN members m ON m.id = p.member_id
     JOIN users u ON u.id = p.coach_id
  WHERE p.organization_id = ((auth.jwt() ->> 'org_id'::text)::uuid)
    AND (auth.jwt() ->> 'app_role'::text) = 'owner'::text
    AND p.status = 'active'::text
    AND ((p.sessions_purchased - p.sessions_used) <= 2
         OR ((p.start_date + make_interval(months => p.duration_months))::date - CURRENT_DATE) <= 7);

COMMENT ON COLUMN public.v_pt_packages_attention.is_paid IS
  'TRUE when the package has a collected payment (success/manual) or costs 0. '
  'Information only - an unpaid package is fully usable and is NOT, by itself, '
  'an attention row.';

CREATE VIEW public.v_pt_package_payment_status AS
SELECT
  pk.id              AS pt_package_id,
  pk.organization_id,
  pk.member_id,
  pk.price,
  (pk.price = 0 OR EXISTS (
     SELECT 1 FROM public.payments pay
      WHERE pay.pt_package_id = pk.id AND public.payment_is_collected(pay.status)
  ))                 AS is_paid
FROM public.pt_packages pk
JOIN public.members m ON m.id = pk.member_id
WHERE pk.organization_id = (auth.jwt() ->> 'org_id')::uuid
  AND (
    (auth.jwt() ->> 'app_role') = 'owner'
    OR (
      (auth.jwt() ->> 'app_role') = 'front_desk'
      AND m.location_id = (auth.jwt() ->> 'location_id')::uuid
    )
  );

COMMENT ON VIEW public.v_pt_package_payment_status IS
  'Paid/unpaid per PT package for the sales desk. DEFINER view that does its own '
  'scoping (owner org-wide, front_desk own location); coaches see nothing. '
  'is_paid = price 0 OR a collected payment exists.';

GRANT SELECT ON public.v_pt_package_payment_status TO authenticated;
