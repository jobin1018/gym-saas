-- payments becomes polymorphic: a payment is for a membership OR a PT package.
-- Implements the deferred plan noted in 20260829091000 ("PAYMENT LINKING —
-- DEFERRED, ON PURPOSE").
--
-- ============================================================================
-- SCHEMA
-- ============================================================================
--   * membership_id becomes NULLABLE.
--   * pt_package_id UUID REFERENCES pt_packages(id) is added.
--   * payments_subject_xor CHECK: EXACTLY ONE of the two is set. `<>` on two
--     booleans is XOR — true only when they differ, so "both set" and
--     "neither set" are both rejected.
--   * a partial index for the PT lookups (revenue view, razorpay-webhook).
--
-- Existing rows all have membership_id set / pt_package_id NULL, so the XOR
-- passes for every one — zero backfill, zero regression.
--
-- ============================================================================
-- HOW A PT PAYMENT ROW GETS CREATED — a trigger, not a new write path
-- ============================================================================
-- A gym PT package is paid at the front desk (cash / UPI) when it is sold, so
-- the revenue is real the moment the package row exists. An AFTER INSERT
-- trigger on pt_packages records it: a 'manual' payment, reconciled now, for
-- the package price. price = 0 (a comp package) gets no row.
--
-- Why a trigger and not "let front_desk INSERT into payments":
--   * payments stays owner-read-only for DIRECT access — the financial-privacy
--     boundary from 20260824140500 (a front-desk PIN cannot see payment
--     history) is untouched. front_desk creates the pt_package (they already
--     can); the payment is a derived record they never see.
--   * same shape as memberships_derive_total_price / pt_packages_derive_
--     sessions — a SECURITY DEFINER derive trigger. It INSERTs into payments,
--     which `authenticated` has no INSERT grant on, so DEFINER + pinned
--     search_path is required (identical discipline to pt_packages_validate_
--     refs).
--
-- FUTURE (Razorpay PT checkout, a fast-follow): that flow will create its own
-- 'pending' payments row and this trigger must then be suppressed for those
-- packages (e.g. a pt_packages.payment_method column, or the checkout code
-- creating the row and setting a flag the trigger checks). Noted, not built —
-- razorpay-webhook's PT reconciliation (companion change) is already in place
-- so only the row-creation half remains.
--
-- ============================================================================
-- RLS — unchanged, and why that is correct
-- ============================================================================
-- tenant_isolation_payments is (org match AND app_role = 'owner'). It is
-- subject-agnostic: a PT payment row is owner-visible in its org exactly like
-- a membership payment, and front_desk sees neither. No policy change.
-- razorpay-webhook (service_role, BYPASSRLS) needs to READ the package on a PT
-- payment for the confirmation message — hence the pt_packages SELECT grant
-- below (members is already granted to service_role).
-- ============================================================================

ALTER TABLE public.payments ALTER COLUMN membership_id DROP NOT NULL;

ALTER TABLE public.payments
  ADD COLUMN pt_package_id UUID REFERENCES public.pt_packages(id);

ALTER TABLE public.payments
  ADD CONSTRAINT payments_subject_xor
    CHECK ((membership_id IS NOT NULL) <> (pt_package_id IS NOT NULL));

CREATE INDEX idx_payments_pt_package
  ON public.payments (organization_id, pt_package_id)
  WHERE pt_package_id IS NOT NULL;

GRANT SELECT ON public.pt_packages TO service_role;

CREATE FUNCTION public.pt_packages_record_payment()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  -- price = 0 -> a comp package, no money changed hands, no payment row.
  IF NEW.price > 0 THEN
    INSERT INTO public.payments
      (organization_id, membership_id, pt_package_id, amount, provider,
       status, idempotency_key, reconciled_at)
    VALUES
      (NEW.organization_id, NULL, NEW.id, NEW.price, 'manual',
       'manual', 'ptpkg-' || NEW.id::text, now());
  END IF;
  RETURN NULL;  -- AFTER trigger: return value is ignored
END;
$$;

REVOKE ALL ON FUNCTION public.pt_packages_record_payment() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.pt_packages_record_payment() FROM anon, authenticated, service_role;

-- AFTER INSERT, so the pt_packages row already exists for the FK, and after
-- pt_packages_derive_sessions / _validate_refs have run (both BEFORE).
CREATE TRIGGER trg_pt_packages_record_payment
  AFTER INSERT ON public.pt_packages
  FOR EACH ROW EXECUTE FUNCTION public.pt_packages_record_payment();

COMMENT ON COLUMN public.payments.pt_package_id IS
  'Set (with membership_id NULL) when this payment is for a PT package. '
  'Exactly one of membership_id / pt_package_id is non-null — payments_subject_xor.';
