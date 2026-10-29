-- Manual payment recording, made future-proof BEFORE real payment data exists.
-- Part 1 of 2: schema, the single "is this money collected?" rule, coverage
-- defaults, and the revenue / ledger views. Part 2 (20261031090500) holds the
-- functions.
--
-- ============================================================================
-- WHAT CHANGES ON payments
-- ============================================================================
--   method            -> RENAMED payment_method. 20260928090000 (record_manual_
--                        payment) already added `method`; a second column for
--                        the same fact would be a duplicate. Allowed values are
--                        now cash | upi | card | bank_transfer ('other' dropped
--                        per the spec). The new CHECK is NOT VALID so any
--                        pre-existing row that still says 'other' does not block
--                        the migration; new and updated rows are enforced.
--   reference         text     free-text receipt / UPI txn reference
--   covers_from/to    date     the membership period this payment pays for,
--                              half-open [covers_from, covers_to)
--   recorded_by       uuid     users.id of the staff member who recorded it
--   received_at       date     the day the money was actually received. Revenue
--                              is bucketed by this day when set.
--   voided_by/at, void_reason  who/when/why a payment was voided
--   note              text     free-text note. NOT in the original column list;
--                              record_manual_payment(p_note) needs somewhere to
--                              put it, and refund_due rows use it to say which
--                              payment they duplicate.
--
-- status gains 'void' and 'refund_due' (keeps pending/success/failed/manual).
--   void        a payment that is no longer real: a manual payment cancelled by
--               the owner, or a pending Razorpay link superseded by a manual
--               payment for the same period. Never counted as revenue.
--   refund_due  Razorpay captured money for a period that was ALREADY covered
--               by a collected payment (e.g. the member paid cash at the desk,
--               then also paid the link). razorpay-webhook records it here
--               instead of extending the membership a second time. Not counted
--               as revenue; it is the owner's to-do list of refunds.
--
-- Constraints added:
--   * payments_manual_method_required: provider = 'manual' needs payment_method.
--     EXEMPTS PT-package rows (pt_package_id set): pt_packages_record_payment()
--     inserts provider='manual' rows with no method, and changing that trigger
--     is a separate, not-yet-approved decision. Drop the exemption when PT sales
--     move to the manual flow. NOT VALID: earlier rows are not re-checked.
--   * void rows must carry voided_at and a non-empty void_reason.
--   * covers_from/covers_to are both set or both null, and covers_to > covers_from.
--
-- ============================================================================
-- ONE RULE FOR "COLLECTED": payment_is_collected(status)
-- ============================================================================
-- status IN ('success','manual'). Everything that sums money (v_daily_revenue,
-- v_daily_revenue_by_source -> REVENUE, the daily owner brief, the ledger's
-- is_collected column) now goes through this one function, so void / refund_due
-- / failed / pending can never leak into revenue through a view that forgot to
-- list them. daily-owner-brief and the WhatsApp REVENUE command read
-- v_daily_revenue_by_source, so they pick this up without a code change.
--
-- REVENUE DAY: date_trunc('day', COALESCE(received_at::timestamptz,
-- reconciled_at, created_at)) — a back-dated desk payment lands on the day the
-- money was received. Rows without received_at (Razorpay, PT sales) behave
-- exactly as before.
--
-- ============================================================================
-- COVERAGE DEFAULTS (trigger)
-- ============================================================================
-- A pending renewal link is created by send-renewal-reminder with no idea about
-- coverage. A BEFORE INSERT trigger fills covers_from/covers_to for a pending
-- membership payment from the membership as it stands: covers_from =
-- GREATEST(today, current_period_end), covers_to = covers_from + duration
-- months — the same rule razorpay-webhook and record_manual_payment use to
-- extend. It lets the webhook later ask "is this period already paid?" without
-- send-renewal-reminder changing. Done in SQL so every insert path gets it.
--
-- ============================================================================
-- RLS / GRANTS
-- ============================================================================
-- payments stays owner-only for direct reads and has no authenticated write
-- grant; the new columns inherit that. All writes go through SECURITY DEFINER
-- functions (part 2) or service_role (razorpay-webhook). front_desk reads
-- payments only through v_payments_ledger, which hides void_reason from them.
-- ============================================================================

ALTER TABLE public.payments RENAME COLUMN method TO payment_method;

ALTER TABLE public.payments DROP CONSTRAINT payments_method_check;
ALTER TABLE public.payments
  ADD CONSTRAINT payments_payment_method_check
    CHECK (payment_method IS NULL
           OR payment_method IN ('cash', 'upi', 'card', 'bank_transfer')) NOT VALID;

COMMENT ON COLUMN public.payments.payment_method IS
  'How a desk-recorded payment was taken: cash | upi | card | bank_transfer. '
  'Required when provider = ''manual'' (PT-package sale rows exempt for now). '
  'NULL for gateway-reconciled rows.';

ALTER TABLE public.payments
  ADD COLUMN reference     TEXT,
  ADD COLUMN covers_from   DATE,
  ADD COLUMN covers_to     DATE,
  ADD COLUMN recorded_by   UUID REFERENCES public.users(id),
  ADD COLUMN received_at   DATE,
  ADD COLUMN voided_by     UUID REFERENCES public.users(id),
  ADD COLUMN voided_at     TIMESTAMPTZ,
  ADD COLUMN void_reason   TEXT,
  ADD COLUMN note          TEXT;

ALTER TABLE public.payments DROP CONSTRAINT payments_status_check;
ALTER TABLE public.payments
  ADD CONSTRAINT payments_status_check
    CHECK (status = ANY (ARRAY['pending', 'success', 'failed', 'manual', 'void', 'refund_due']));

ALTER TABLE public.payments
  ADD CONSTRAINT payments_manual_method_required
    CHECK (provider <> 'manual' OR payment_method IS NOT NULL OR pt_package_id IS NOT NULL) NOT VALID,
  ADD CONSTRAINT payments_void_fields
    CHECK (status <> 'void'
           OR (voided_at IS NOT NULL AND void_reason IS NOT NULL AND btrim(void_reason) <> '')),
  ADD CONSTRAINT payments_coverage_consistent
    CHECK ((covers_from IS NULL) = (covers_to IS NULL)
           AND (covers_from IS NULL OR covers_to > covers_from));

CREATE INDEX idx_payments_membership_cover
  ON public.payments (membership_id, covers_from, covers_to)
  WHERE covers_from IS NOT NULL;

COMMENT ON COLUMN public.payments.covers_from IS
  'Start (inclusive) of the membership period this payment pays for.';
COMMENT ON COLUMN public.payments.covers_to IS
  'End (exclusive) of the membership period this payment pays for; equals the '
  'membership''s current_period_end after the payment is applied.';
COMMENT ON COLUMN public.payments.received_at IS
  'Date the money was received (desk payments may be back-dated up to 7 days). '
  'Revenue views bucket by this day when set.';

-- ---------------------------------------------------------------------------
-- The single collected rule
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.payment_is_collected(p_status text)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
AS $$ SELECT p_status IN ('success', 'manual') $$;

COMMENT ON FUNCTION public.payment_is_collected(text) IS
  'The one definition of "this money has actually been collected": status '
  'success (gateway) or manual (desk). void, refund_due, failed and pending are '
  'never collected. Used by the revenue views, the ledger and the daily brief.';

-- ---------------------------------------------------------------------------
-- Coverage defaults for pending membership payments
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.payments_default_coverage()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_end      date;
  v_duration integer;
BEGIN
  IF NEW.membership_id IS NOT NULL AND NEW.covers_from IS NULL AND NEW.status = 'pending' THEN
    SELECT ms.current_period_end, ms.duration_months
      INTO v_end, v_duration
      FROM public.memberships ms WHERE ms.id = NEW.membership_id;
    IF v_end IS NOT NULL THEN
      NEW.covers_from := GREATEST(CURRENT_DATE, v_end);
      NEW.covers_to   := (NEW.covers_from + (v_duration || ' months')::interval)::date;
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.payments_default_coverage() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.payments_default_coverage() FROM anon, authenticated, service_role;

CREATE TRIGGER trg_payments_default_coverage
  BEFORE INSERT ON public.payments
  FOR EACH ROW EXECUTE FUNCTION public.payments_default_coverage();

-- ---------------------------------------------------------------------------
-- Revenue views: collected rule + received_at day. Same columns, same
-- security_invoker=true (owner-only through payments' own RLS).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.v_daily_revenue
WITH (security_invoker = true) AS
SELECT
  organization_id,
  date_trunc('day', COALESCE(received_at::timestamptz, reconciled_at, created_at)) AS day,
  SUM(amount)  AS total,
  COUNT(*)     AS payment_count
FROM public.payments
WHERE public.payment_is_collected(status)
GROUP BY organization_id,
         date_trunc('day', COALESCE(received_at::timestamptz, reconciled_at, created_at));

CREATE OR REPLACE VIEW public.v_daily_revenue_by_source
WITH (security_invoker = true) AS
SELECT
  organization_id,
  date_trunc('day', COALESCE(received_at::timestamptz, reconciled_at, created_at)) AS day,
  CASE WHEN pt_package_id IS NOT NULL THEN 'pt_package' ELSE 'membership' END AS source,
  SUM(amount)  AS total,
  COUNT(*)     AS payment_count
FROM public.payments
WHERE public.payment_is_collected(status)
GROUP BY
  organization_id,
  date_trunc('day', COALESCE(received_at::timestamptz, reconciled_at, created_at)),
  (CASE WHEN pt_package_id IS NOT NULL THEN 'pt_package' ELSE 'membership' END);

COMMENT ON VIEW public.v_daily_revenue IS
  'Collected revenue per org per day (membership + PT). "Collected" = '
  'payment_is_collected(status): success + manual only, so void / refund_due / '
  'failed / pending never count. Day = received_at when set, else reconciled_at, '
  'else created_at. security_invoker=true -> payments'' owner-only RLS applies.';
COMMENT ON VIEW public.v_daily_revenue_by_source IS
  'v_daily_revenue split by source (''membership'' | ''pt_package''); same '
  'collected rule and day bucketing. security_invoker=true.';

-- ---------------------------------------------------------------------------
-- Ledger: new columns APPENDED (CREATE OR REPLACE VIEW cannot reorder), same
-- DEFINER scoping. front_desk keeps location scoping and sees no void reasons.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.v_payments_ledger AS
SELECT
  p.id,
  p.organization_id,
  m.id                                    AS member_id,
  m.name                                  AS member_name,
  m.location_id,
  COALESCE(p.received_at::timestamptz, p.reconciled_at, p.created_at) AS transaction_date,
  p.amount,
  p.status,
  p.provider,
  p.provider_payment_id,
  CASE
    WHEN p.membership_id IS NOT NULL THEN 'membership'
    ELSE 'personal_training'
  END                                     AS payment_type,
  p.payment_method,
  p.reference,
  u.name                                  AS recorded_by_name,
  p.received_at,
  (p.status = 'void')                     AS is_void,
  public.payment_is_collected(p.status)   AS is_collected,
  CASE WHEN (auth.jwt() ->> 'app_role') = 'owner' THEN p.void_reason END AS void_reason
FROM public.payments p
LEFT JOIN public.memberships ms ON ms.id = p.membership_id
LEFT JOIN public.pt_packages pk ON pk.id = p.pt_package_id
LEFT JOIN public.users u ON u.id = p.recorded_by
JOIN public.members m ON m.id = COALESCE(ms.member_id, pk.member_id)
WHERE p.organization_id = (auth.jwt() ->> 'org_id')::uuid
  AND (
    (auth.jwt() ->> 'app_role') = 'owner'
    OR (
      (auth.jwt() ->> 'app_role') = 'front_desk'
      AND m.location_id = (auth.jwt() ->> 'location_id')::uuid
    )
  );

COMMENT ON VIEW public.v_payments_ledger IS
  'Per-transaction payment ledger (DEFINER view; owner org-wide, front_desk own '
  'location). Includes void and refund_due rows, flagged by is_void / status; '
  'is_collected is the single revenue rule. void_reason is returned to owners '
  'only (NULL for front_desk). recorded_by_name is the staff member who '
  'recorded a desk payment. transaction_date = received_at, else reconciled_at, '
  'else created_at.';
