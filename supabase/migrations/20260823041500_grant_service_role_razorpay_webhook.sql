-- Grants for the razorpay-webhook Edge Function.
--
-- WHY THIS IS NEEDED: `auto_expose_new_tables` is not enabled (see config.toml),
-- which matches the current Supabase cloud default — tables created by a
-- migration are NOT automatically reachable by the Data API roles. RLS bypass
-- and table privileges are two different things: `service_role` has BYPASSRLS,
-- but without a GRANT every query still fails with
-- `42501 permission denied for table ...`.
--
-- Scope is minimum-privilege: only the tables/operations razorpay-webhook
-- actually performs. Grants are idempotent, so overlap with
-- 20260822044500_grant_service_role_webhook_access.sql is harmless — repeating
-- them keeps each function's requirements readable in one place.

-- Idempotency ledger: insert the event, read back its id, then flip processed.
--
-- NOTE: UPDATE is required here even though the whatsapp grants migration is
-- the "reference pattern". Step 4 of this function sets processed = true, which
-- is an UPDATE; SELECT+INSERT alone would fail at the last line of every
-- otherwise-successful delivery.
GRANT SELECT, INSERT, UPDATE ON public.webhook_events TO service_role;

-- Reconciliation target: match Razorpay's entity to a payments row, then mark
-- it success/failed and stamp reconciled_at.
GRANT SELECT, UPDATE ON public.payments TO service_role;

-- Period extension: read current_period_end, write the new one and set the
-- membership active.
GRANT SELECT, UPDATE ON public.memberships TO service_role;

-- Outbound confirmation / failure notice audit log.
GRANT SELECT, INSERT ON public.whatsapp_messages TO service_role;

-- NOTE: members is not in the "payments/memberships/webhook_events/
-- whatsapp_messages" set, but the function cannot do its job without it — the
-- payment confirmation has to be addressed to a phone number, and phone lives
-- on members. The read is one nested embed off memberships.member_id.
GRANT SELECT ON public.members TO service_role;
