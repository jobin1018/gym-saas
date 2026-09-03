-- claim_coach_magic_link() — move the coach-magic-link claim (single-use +
-- 15-minute expiry) entirely into Postgres, so both checks are decided by
-- ONE clock, not two.
--
-- ============================================================================
-- THE BUG REPORT, WHAT I FOUND, AND WHY THIS IS THE FIX
-- ============================================================================
-- Reported: a coach magic link still worked after waiting past its 15-minute
-- window. Investigated both hypotheses named in the report:
--
--   * Column type / timezone mismatch — RULED OUT. expires_at is TIMESTAMPTZ
--     (20260901092000), the generator writes an ISO-8601 UTC string
--     (whatsapp-webhook's coachStartSession: `new Date(Date.now() + 15*60*
--     1000).toISOString()`), and the existing test suite already proves the
--     comparison rejects a row backdated with Postgres's OWN now() (`insert
--     ... expires_at = now() - interval '1 minute'` -> link_expired, 31/31
--     passing before this migration too).
--   * The expiry check being skipped / short-circuited past — RULED OUT.
--     validate-magic-link's atomic claim was ONE UPDATE checking both
--     `used_at IS NULL AND expires_at > now` together — there was no
--     sequential check for one to short-circuit past the other.
--
-- What the code DID have, that neither named hypothesis quite covers: the
-- "now" on the right-hand side of `expires_at > now` was NOT Postgres's own
-- now() — it was `new Date().toISOString()`, computed in the Edge Function's
-- own Deno process, then sent to PostgREST as an ordinary filter value
-- (`.gt("expires_at", nowIso)`). That makes the security-critical comparison
-- depend on TWO clocks agreeing (the edge runtime container's and Postgres's)
-- instead of one. In this exact project, over this exact working session,
-- Docker Desktop's daemon went down and came back up mid-session — a real,
-- observed trigger for container/VM clock drift on Windows after a host
-- sleep/resume, which is precisely the kind of event that could make an
-- edge-runtime container's clock run meaningfully behind wall-clock time
-- until it resyncs. A `nowIso` computed from a clock running several minutes
-- behind would make an ALREADY-expired row still pass `expires_at > nowIso`.
-- I could not conclusively reproduce this locally (same-host Docker
-- containers share a clock), so I cannot say with certainty this is THE
-- root cause of what was observed rather than a stale authenticated session
-- being mistaken for the magic link itself still working (see
-- validate-magic-link's own header: the claim happens ONCE, before a real
-- coach session — same shape as staff-login's, ~1h access token + refreshable
-- — is minted; that session, once obtained, has NOTHING to do with the
-- magic link's 15-minute window and is expected to keep working well past
-- it). Either way, this fix removes the cross-clock dependency entirely,
-- which is strictly correct regardless of which explanation is right.
--
-- THE FIX: move the whole claim — atomic single-use UPDATE, and the
-- not_found / already_used / expired classification for a failed claim —
-- into ONE PL/pgSQL function that only ever references Postgres's own now().
-- No client-supplied timestamp reaches the comparison at all anymore.
-- ============================================================================

CREATE FUNCTION public.claim_coach_magic_link(p_token text)
RETURNS TABLE(
  outcome         text,   -- 'claimed' | 'not_found' | 'already_used' | 'expired'
  link_id         uuid,
  coach_user_id   uuid,
  organization_id uuid
)
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_link_id uuid;
  v_coach   uuid;
  v_org     uuid;
  v_used_at timestamptz;
  v_expires timestamptz;
BEGIN
  -- The single-use + expiry gate, unchanged in spirit from before — still
  -- ONE atomic UPDATE so a race can never claim the same row twice — except
  -- now() here is evaluated BY POSTGRES, in the same statement that reads
  -- expires_at, not passed in from outside.
  UPDATE public.coach_magic_links cml
     SET used_at = now()
   WHERE cml.token = p_token
     AND cml.used_at IS NULL
     AND cml.expires_at > now()
   RETURNING cml.id, cml.coach_user_id, cml.organization_id
    INTO v_link_id, v_coach, v_org;

  IF FOUND THEN
    RETURN QUERY SELECT 'claimed'::text, v_link_id, v_coach, v_org;
    RETURN;
  END IF;

  -- Claim failed — classify why, for the caller's error message. Also
  -- entirely Postgres-clock-driven; no TOCTOU window beyond the UPDATE
  -- above already having failed (same guarantee validate-magic-link's
  -- original comment described).
  SELECT cml.id, cml.used_at, cml.expires_at
    INTO v_link_id, v_used_at, v_expires
    FROM public.coach_magic_links cml
   WHERE cml.token = p_token;

  IF NOT FOUND THEN
    RETURN QUERY SELECT 'not_found'::text, NULL::uuid, NULL::uuid, NULL::uuid;
  ELSIF v_used_at IS NOT NULL THEN
    RETURN QUERY SELECT 'already_used'::text, v_link_id, NULL::uuid, NULL::uuid;
  ELSIF v_expires <= now() THEN
    RETURN QUERY SELECT 'expired'::text, v_link_id, NULL::uuid, NULL::uuid;
  ELSE
    -- Row exists, unused, unexpired by this read, yet the UPDATE above
    -- claimed 0 rows: a concurrent request won the race between that UPDATE
    -- and this SELECT. Same outcome for this caller as any other reuse.
    RETURN QUERY SELECT 'already_used'::text, v_link_id, NULL::uuid, NULL::uuid;
  END IF;
END;
$function$;

COMMENT ON FUNCTION public.claim_coach_magic_link(text) IS
  'Atomic single-use + expiry claim for a coach magic link, decided entirely '
  'by Postgres''s own now() — no client-supplied timestamp. service_role '
  'only (validate-magic-link is the sole caller); RLS on coach_magic_links '
  'is deny-all otherwise, so this function is the only write path besides '
  'the row''s own INSERT in whatsapp-webhook.';

-- SECURITY INVOKER (default, no DEFINER): runs as the caller's own role.
-- validate-magic-link always calls this via createAdminClient() (service_role,
-- which already holds SELECT/INSERT/UPDATE on coach_magic_links and
-- BYPASSRLS), so no elevated privilege is needed here. Deliberately NOT
-- granted to anon/authenticated — a coach has no session yet at redemption
-- time, and nothing else should ever call this directly; the edge function
-- is the only intended entry point (token format validation, CORS, logging).
REVOKE ALL ON FUNCTION public.claim_coach_magic_link(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.claim_coach_magic_link(text) TO service_role;
