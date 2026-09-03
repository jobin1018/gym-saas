-- Grants for the whatsapp-webhook Edge Function.
--
-- WHY THIS IS NEEDED: `auto_expose_new_tables` is not enabled (see config.toml),
-- which matches the current Supabase cloud default — tables created by a
-- migration are NOT automatically reachable by the Data API roles. RLS bypass
-- and table privileges are two different things: `service_role` has BYPASSRLS,
-- but without a GRANT every query still fails with
-- `42501 permission denied for table ...`.
--
-- Scope is deliberately minimum-privilege: only the tables/operations the
-- whatsapp-webhook function actually performs. Each new Edge Function should
-- add its own grants here rather than blanket-granting the schema. (If you'd
-- rather opt into the legacy auto-expose behaviour instead, set
-- `auto_expose_new_tables = true` under [api] in config.toml — but note that
-- field is scheduled for removal on 2026-10-30.)

-- Idempotency ledger: insert the event, read back its id, flip processed.
GRANT SELECT, INSERT, UPDATE ON public.webhook_events TO service_role;

-- Tenant resolution: find the member(s) behind an inbound phone number and
-- name their gyms in disambiguation prompts.
GRANT SELECT ON public.members       TO service_role;
GRANT SELECT ON public.organizations TO service_role;

-- Sticky "which gym is this phone at" pointer — upserted on first contact.
GRANT SELECT, INSERT, UPDATE ON public.member_active_context TO service_role;

-- Check-in eligibility.
GRANT SELECT ON public.memberships TO service_role;

-- Self-service check-in.
GRANT INSERT ON public.attendance TO service_role;

-- Inbound/outbound message log.
GRANT SELECT, INSERT ON public.whatsapp_messages TO service_role;
