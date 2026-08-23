-- Grants for the renewal-scan Edge Function.
--
-- WHY THIS IS NEEDED: `auto_expose_new_tables` is not enabled (see config.toml),
-- which matches the current Supabase cloud default — tables created by a
-- migration are NOT automatically reachable by the Data API roles. RLS bypass
-- and table privileges are two different things: `service_role` has BYPASSRLS,
-- but without a GRANT every query still fails with
-- `42501 permission denied for table ...`.
--
-- Scope is minimum-privilege: only the tables/operations renewal-scan actually
-- performs. Grants are idempotent, so overlap with the three earlier grants
-- migrations is harmless — repeating them keeps each function's requirements
-- readable in one place.
--
-- ============================================================================
-- THIS FUNCTION IS READ-ONLY. THAT IS THE WHOLE POINT.
-- ============================================================================
-- renewal-scan selects memberships and calls send-renewal-reminder once per
-- match. Every row written during a scan — the payments row, the
-- whatsapp_messages row — is written by send-renewal-reminder under ITS grants,
-- not these. So there is no INSERT or UPDATE anywhere below, on any table.
--
-- Withholding write privileges here is not ceremony: it means a bug in the
-- scanner (a bad offset override, a runaway loop) can at worst call the
-- reminder function too often, where the reminder function's own idempotency
-- absorbs it. The scanner cannot corrupt a payment or a membership directly
-- even if it tries.

-- The selection query itself: status and current_period_end are the filters,
-- and the row is what gets handed to send-renewal-reminder.
GRANT SELECT ON public.memberships TO service_role;

-- NOTE: the brief for this function said "SELECT on memberships" only, and for
-- a send-only scan that would be enough — the fan-out passes nothing but a
-- membership_id. The two grants below exist because of dry_run: reporting what
-- WOULD be sent has to name the member and show the amount, or it cannot serve
-- its purpose of sanity-checking the query against real data before trusting it
-- with real money. Both are read-only, and both are nested embeds off
-- memberships.member_id / .plan_id in a single round trip.
GRANT SELECT ON public.members          TO service_role;
GRANT SELECT ON public.membership_plans TO service_role;
