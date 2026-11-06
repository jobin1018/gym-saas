-- org_payment_settings — per-gym choice of how members pay a renewal.
--
-- One row per org. Absence of a row means "legacy gym": send-renewal-reminder
-- keeps using Razorpay exactly as before (see _shared/payment-mode.ts). A row
-- is authoritative: razorpay_enabled defaults FALSE, so an owner who saves UPI
-- details without ticking Razorpay is choosing UPI QR only.
--
-- Access: owner read/write own org; front_desk read-only own org; coach and
-- anon get nothing. A suspended org is refused by the same RESTRICTIVE
-- org_not_suspended gate every other tenant table carries.

CREATE TABLE public.org_payment_settings (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id  UUID NOT NULL UNIQUE REFERENCES public.organizations(id),
  upi_id           TEXT,
  qr_image_path    TEXT,
  qr_enabled       BOOLEAN NOT NULL DEFAULT false,
  razorpay_enabled BOOLEAN NOT NULL DEFAULT false,
  updated_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT org_payment_settings_upi_format
    CHECK (upi_id IS NULL OR upi_id ~ '^[A-Za-z0-9._-]{2,64}@[A-Za-z][A-Za-z0-9]{1,63}$'),
  -- The QR must live in the org's own storage folder (<org_id>/...), so one
  -- org can never point its settings at another org's image.
  CONSTRAINT org_payment_settings_qr_path_in_org_folder
    CHECK (qr_image_path IS NULL
           OR (qr_image_path LIKE organization_id::text || '/%'
               AND qr_image_path !~ '\.\.'))
);

COMMENT ON TABLE public.org_payment_settings IS
  'Per-org payment mode switches (UPI QR / Razorpay). No row = legacy Razorpay. '
  'Owner read/write, front_desk read-only, own org only.';

ALTER TABLE public.org_payment_settings ENABLE ROW LEVEL SECURITY;

CREATE POLICY ops_select ON public.org_payment_settings
  FOR SELECT TO authenticated
  USING (organization_id = (auth.jwt() ->> 'org_id')::uuid
         AND (auth.jwt() ->> 'app_role') IN ('owner', 'front_desk'));

CREATE POLICY ops_insert ON public.org_payment_settings
  FOR INSERT TO authenticated
  WITH CHECK (organization_id = (auth.jwt() ->> 'org_id')::uuid
              AND (auth.jwt() ->> 'app_role') = 'owner');

CREATE POLICY ops_update ON public.org_payment_settings
  FOR UPDATE TO authenticated
  USING (organization_id = (auth.jwt() ->> 'org_id')::uuid
         AND (auth.jwt() ->> 'app_role') = 'owner')
  WITH CHECK (organization_id = (auth.jwt() ->> 'org_id')::uuid
              AND (auth.jwt() ->> 'app_role') = 'owner');

CREATE POLICY org_not_suspended ON public.org_payment_settings
  AS RESTRICTIVE FOR ALL TO public
  USING (public.current_org_active()) WITH CHECK (public.current_org_active());

CREATE FUNCTION public.org_payment_settings_touch()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN NEW.updated_at := now(); RETURN NEW; END $$;

CREATE TRIGGER trg_org_payment_settings_touch
  BEFORE UPDATE ON public.org_payment_settings
  FOR EACH ROW EXECUTE FUNCTION public.org_payment_settings_touch();

REVOKE ALL ON public.org_payment_settings FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE ON public.org_payment_settings TO authenticated;
GRANT SELECT ON public.org_payment_settings TO service_role;
