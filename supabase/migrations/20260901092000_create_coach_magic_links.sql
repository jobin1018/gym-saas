-- coach_magic_links — short-lived, single-use tokens that let a coach start a
-- session-logging session from WhatsApp without their PIN.
--
-- ============================================================================
-- WHY THIS EXISTS
-- ============================================================================
-- Coaches log sessions at the gym floor, from a phone, with no laptop. A
-- conversational WhatsApp flow (pick a client by free text, etc.) is
-- error-prone. Instead: the coach texts SESSION, whatsapp-webhook mints a row
-- here and replies with a link; validate-magic-link redeems the token for a
-- real coach session (see that function's header for the full security
-- reasoning).
--
-- ============================================================================
-- SECURITY SHAPE OF THIS TABLE
-- ============================================================================
--  * token — 32 bytes from crypto.getRandomValues, base64url (~43 chars).
--    256 bits of entropy: unguessable, so validation is a plain lookup, no
--    HMAC needed. UNIQUE so a collision is a hard error, never a silent
--    cross-coach mix-up.
--  * expires_at — set by the generator to now() + 15 minutes. "I'm about to
--    log a session right now" does not need longer, and a short window
--    shrinks the leak surface.
--  * used_at — stamped atomically on first redemption
--    (UPDATE ... WHERE used_at IS NULL RETURNING). A second redemption of the
--    same token updates 0 rows and is rejected. Single-use is enforced here,
--    at the row, not in application logic.
--  * coach_user_id / organization_id — the session validate-magic-link mints
--    is for THIS coach only. A leaked link can do nothing outside that one
--    coach's normal RLS scope (their active clients; a session note /
--    measurement). No financial data, no other coaches, no admin capability.
--  * The row is the AUDIT TRAIL: created_at = generated, used_at = redeemed,
--    both attributable to a coach + org. Rows are kept (no DELETE grant); a
--    prune job for old rows is a later, optional concern.
--
-- RLS is ENABLED with NO policy: anon/authenticated get deny-all (nobody
-- browses magic links). Only service_role touches this table, and only via
-- the two functions' createAdminClient(). Grants are in the companion
-- migration.
-- ============================================================================

CREATE TABLE public.coach_magic_links (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  coach_user_id   UUID NOT NULL REFERENCES public.users(id),
  organization_id UUID NOT NULL REFERENCES public.organizations(id),
  token           TEXT NOT NULL UNIQUE,
  expires_at      TIMESTAMPTZ NOT NULL,
  used_at         TIMESTAMPTZ,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- "the latest link this coach generated" / audit browsing by coach.
CREATE INDEX idx_coach_magic_links_coach
  ON public.coach_magic_links (coach_user_id, created_at DESC);

ALTER TABLE public.coach_magic_links ENABLE ROW LEVEL SECURITY;
-- Deliberately no CREATE POLICY: RLS on + no policy = deny-all for every role
-- except those that BYPASSRLS (service_role). See the header.
