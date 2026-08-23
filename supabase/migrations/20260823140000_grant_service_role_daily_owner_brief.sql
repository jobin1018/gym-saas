-- Grants for the daily-owner-brief Edge Function.
--
-- WHY THIS IS NEEDED: `auto_expose_new_tables` is not enabled (see config.toml),
-- which matches the current Supabase cloud default — tables created by a
-- migration are NOT automatically reachable by the Data API roles. RLS bypass
-- and table privileges are two different things: `service_role` has BYPASSRLS,
-- but without a GRANT every query still fails with
-- `42501 permission denied for table ...`.
--
-- Scope is minimum-privilege: only the tables/operations daily-owner-brief
-- actually performs. Grants are idempotent, so overlap with the four earlier
-- grants migrations is harmless — repeating them keeps each function's
-- requirements readable in one place.
--
-- This function reads five tables and writes exactly one. Nothing it reports on
-- is mutated by reporting on it: no membership is advanced, no payment is
-- touched, no attendance row is written. The single INSERT is the outbound
-- message log, which is also this function's own once-per-day guard.

-- The recipient list. status IN ('trial','active') selects who gets a brief;
-- owner_phone is the address; name goes in the first line of the message.
GRANT SELECT ON public.organizations TO service_role;

-- NEW IN THIS MIGRATION: none of the previous four functions read this table.
-- The brief needs it for one column — locations.timezone — because "yesterday's
-- check-ins" and "already briefed today" are calendar-day questions that have
-- no answer until you know whose calendar. A gym in IST closing at 23:00 must
-- not have that evening's check-ins counted as the next day's, which is exactly
-- what a UTC day boundary at 05:30 IST would do.
GRANT SELECT ON public.locations TO service_role;

-- Renewals due this week and overdue: current_period_end and status are the
-- filters, and the plan supplies the rupee amounts for both figures.
GRANT SELECT ON public.memberships      TO service_role;
GRANT SELECT ON public.membership_plans TO service_role;

-- NOTE: payments is granted because the brief reports on money, and the two
-- money figures are currently derived from membership_plans.amount (what the
-- member is signed up to pay) rather than from payments rows (what has been
-- billed). Both readings are defensible; see the note in index.ts. The grant is
-- here so switching the overdue figure to "sum of pending payments" is a code
-- change and not a permissions incident at 07:00 on a Monday.
GRANT SELECT ON public.payments TO service_role;

-- Yesterday's check-ins, counted in the organization's own timezone.
GRANT SELECT ON public.attendance TO service_role;

-- Two distinct uses, both essential:
--   SELECT — the failed-send count reported IN the brief, and the once-per-day
--            guard that stops an org being briefed twice.
--   INSERT — the brief itself. This row carries member_id = NULL, because the
--            recipient is organizations.owner_phone rather than a member; the
--            column is nullable and no other query in the codebase assumes
--            otherwise (send-renewal-reminder's guard filters on an explicit
--            member_id, which a NULL row can never match).
GRANT SELECT, INSERT ON public.whatsapp_messages TO service_role;
