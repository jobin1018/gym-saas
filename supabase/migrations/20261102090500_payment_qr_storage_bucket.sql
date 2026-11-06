-- Private Storage bucket for each gym's UPI QR image.
--
-- Layout: payment-qr/<organization_id>/<file>. The size and type limits are
-- bucket settings, so Storage enforces them server-side whatever the client
-- sends: 2 MB, image/png and image/jpeg only. (Type is the declared
-- Content-Type; Storage does not sniff bytes.)
--
-- Policies: owner of that org uploads/replaces/deletes inside their own
-- folder; owner and front_desk may read it. Nobody else (anon included).
-- Pay-page access is by short-lived signed URL minted by get-pay-page with the
-- service role, which bypasses these policies.

INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES ('payment-qr', 'payment-qr', false, 2097152, ARRAY['image/png', 'image/jpeg'])
ON CONFLICT (id) DO UPDATE
  SET public = false,
      file_size_limit = 2097152,
      allowed_mime_types = ARRAY['image/png', 'image/jpeg'];

CREATE POLICY payment_qr_owner_insert ON storage.objects
  FOR INSERT TO authenticated
  WITH CHECK (bucket_id = 'payment-qr'
              AND (auth.jwt() ->> 'app_role') = 'owner'
              AND (storage.foldername(name))[1] = (auth.jwt() ->> 'org_id')
              AND public.current_org_active());

CREATE POLICY payment_qr_owner_update ON storage.objects
  FOR UPDATE TO authenticated
  USING (bucket_id = 'payment-qr'
         AND (auth.jwt() ->> 'app_role') = 'owner'
         AND (storage.foldername(name))[1] = (auth.jwt() ->> 'org_id')
         AND public.current_org_active())
  WITH CHECK (bucket_id = 'payment-qr'
              AND (auth.jwt() ->> 'app_role') = 'owner'
              AND (storage.foldername(name))[1] = (auth.jwt() ->> 'org_id')
              AND public.current_org_active());

CREATE POLICY payment_qr_owner_delete ON storage.objects
  FOR DELETE TO authenticated
  USING (bucket_id = 'payment-qr'
         AND (auth.jwt() ->> 'app_role') = 'owner'
         AND (storage.foldername(name))[1] = (auth.jwt() ->> 'org_id')
         AND public.current_org_active());

CREATE POLICY payment_qr_staff_select ON storage.objects
  FOR SELECT TO authenticated
  USING (bucket_id = 'payment-qr'
         AND (auth.jwt() ->> 'app_role') IN ('owner', 'front_desk')
         AND (storage.foldername(name))[1] = (auth.jwt() ->> 'org_id')
         AND public.current_org_active());
