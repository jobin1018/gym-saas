-- Grants for the send-welcome-message Edge Function.
--
-- ============================================================================
-- WHAT THIS FUNCTION TOUCHES
-- ============================================================================
--   SELECT  public.users             — resolve the caller from the bearer token
--   SELECT  public.members           — load the new member, confirm same org
--   SELECT  public.organizations     — org name (template param) + status guard
--   SELECT  public.whatsapp_messages — idempotency check (one welcome per member)
--   INSERT  public.whatsapp_messages — the outbound audit row
--
-- service_role ALREADY holds every one of these (users/members/organizations
-- SELECT from the core schema + 20260824130500; whatsapp_messages SELECT+INSERT
-- from 20260822044500) — verified against information_schema.role_table_grants
-- before writing this, not assumed. So this migration grants nothing new.
--
-- It exists to make this function's DB footprint auditable in one place, the
-- same way every other Edge Function has a companion grants migration, and to
-- be the obvious home for a new grant if send-welcome-message ever writes
-- another table. The statements below are idempotent re-affirmations.
-- ============================================================================

GRANT SELECT ON public.users             TO service_role;
GRANT SELECT ON public.members           TO service_role;
GRANT SELECT ON public.organizations     TO service_role;
GRANT SELECT, INSERT ON public.whatsapp_messages TO service_role;
