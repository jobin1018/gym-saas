-- membership_renewal_amount was documented as "granted to service_role only"
-- (20261030090500), but that migration only revoked from PUBLIC. Supabase's
-- default privileges on schema public grant EXECUTE to anon and authenticated
-- by name, so REVOKE ... FROM PUBLIC left both able to call it: any staff
-- session (or anon key) could read the renewal price of any membership id.
-- The only caller is send-renewal-reminder (service role). Revoke explicitly.
REVOKE ALL ON FUNCTION public.membership_renewal_amount(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.membership_renewal_amount(uuid) TO service_role;
