-- Grants for the send-renewal-reminder Edge Function.
--
-- WHY THIS IS NEEDED: `auto_expose_new_tables` is not enabled (see config.toml),
-- which matches the current Supabase cloud default — tables created by a
-- migration are NOT automatically reachable by the Data API roles. RLS bypass
-- and table privileges are two different things: `service_role` has BYPASSRLS,
-- but without a GRANT every query still fails with
-- `42501 permission denied for table ...`.
--
-- Scope is minimum-privilege: only the tables/operations send-renewal-reminder
-- actually performs. Grants are idempotent, so overlap with the two earlier
-- grants migrations is harmless — repeating them keeps each function's
-- requirements readable in one place.
--
-- NOTE ON WHAT IS *NOT* GRANTED: no UPDATE on payments, and no UPDATE on
-- memberships. This function only ever creates the pending payment; advancing
-- it to success/failed and extending the period are razorpay-webhook's job.
-- Withholding UPDATE here is what keeps that boundary enforced by the database
-- rather than by convention — and it is the reason index.ts fails loudly with
-- `payment_link_unrecoverable` instead of quietly creating a second Razorpay
-- link it would have no way to record.

-- Read the renewal target: status, current_period_end, and the FKs used to
-- reach the member and the plan below.
GRANT SELECT ON public.memberships TO service_role;

-- Addressee of the reminder — name and phone for the message, whatsapp_opt_in
-- for the consent guard. Read as a nested embed off memberships.member_id.
GRANT SELECT ON public.members TO service_role;

-- Price of the renewal. NEW IN THIS MIGRATION: neither webhook needed this
-- table, because both are told the amount by the provider payload. This
-- function is the one that decides the amount, so it has to read the plan.
GRANT SELECT ON public.membership_plans TO service_role;

-- The pending payment row razorpay-webhook later reconciles.
--   INSERT — create it (status 'pending', razorpay_link_id set,
--            provider_payment_id NULL). NEW IN THIS MIGRATION: the razorpay
--            grants gave service_role SELECT+UPDATE on payments, never INSERT.
--   SELECT — the idempotency_key lookup that reuses an existing row for this
--            renewal period instead of creating a second payment link, plus the
--            read-back after the unique-violation race.
GRANT SELECT, INSERT ON public.payments TO service_role;

-- Outbound reminder audit log. SELECT is not incidental here: the
-- "one reminder per member per day" guard IS a SELECT over this table, so
-- without it the function would re-message a member on every call.
GRANT SELECT, INSERT ON public.whatsapp_messages TO service_role;
