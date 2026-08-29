-- log_session(...) — write one coaching session (a note, plus an optional
-- linked weigh-in) as a single atomic unit.
--
-- ============================================================================
-- WHY AN RPC HERE, WHEN pt_packages / training_notes / body_measurements
-- WRITES ARE OTHERWISE DIRECT
-- ============================================================================
-- 20260829092000's reasoning still stands for a SINGLE row: RLS expresses who
-- may write, so a direct authenticated INSERT is right and an Edge Function
-- would buy nothing. The unified "Session" is different in exactly one way
-- that matters: it is TWO dependent inserts. training_notes must be written
-- first (its id becomes body_measurements.training_note_id), and if the
-- second insert then fails the frontend is left with a note saved, a session
-- counted, and the weigh-in silently lost — the same non-transactional foot-
-- gun memberWrites.ts already carries a comment apologising for.
--
-- PostgREST gives the browser no way to wrap two inserts in one transaction.
-- A plpgsql function body IS one transaction: both rows commit or neither
-- does. That — not authorization, not secrets, not external calls — is the
-- whole reason this function exists. It is still NOT an Edge Function (no
-- service_role, no network hop); it is the smallest thing that makes the pair
-- atomic.
--
-- SECURITY INVOKER, deliberately: the function does nothing privileged. Both
-- INSERTs pass through the caller's own RLS —
-- tenant_isolation_training_notes / _body_measurements WITH CHECK still
-- enforce "the assigned coach, active package" exactly as for a direct
-- insert. A non-assigned member => the training_notes INSERT raises 42501 =>
-- the whole function rolls back => PostgREST 403. There is no code path here
-- that can grant more than the coach already has; this is a transaction
-- wrapper, not a trust boundary.
--
-- ============================================================================
-- CONTRACT
-- ============================================================================
--   log_session(
--     p_member_id     uuid,     -- required
--     p_pt_package_id uuid,     -- required; must be an ACTIVE package for
--                               --   (p_member_id, caller) or RLS rejects
--     p_note_text     text,     -- required; the session always produces a note
--     p_session_date  date    = CURRENT_DATE,
--     p_weight_kg     numeric = NULL,   -- both-or-neither with p_height_cm
--     p_height_cm     numeric = NULL
--   ) returns one row:
--     training_note_id uuid, body_measurement_id uuid|null,
--     sessions_used int, sessions_purchased int, package_status text
--
-- organization_id and coach_id/recorded_by are taken from the JWT
-- (org_id / user_id claims), never from arguments — fewer params to spoof and
-- nothing for the caller to get wrong.
--
-- A note is mandatory because sessions_used counts training_notes
-- (20260829094500). A pure weigh-in with no note is not a "session": use a
-- direct INSERT into body_measurements (training_note_id left NULL) for that.
--
-- The returned sessions_used / package_status reflect the state AFTER the
-- 20260829094500 trigger has run — so a caller that logs the final session
-- sees package_status = 'completed' come back without a re-fetch.
-- ============================================================================

CREATE FUNCTION public.log_session(
  p_member_id     uuid,
  p_pt_package_id uuid,
  p_note_text     text,
  p_session_date  date    DEFAULT CURRENT_DATE,
  p_weight_kg     numeric DEFAULT NULL,
  p_height_cm     numeric DEFAULT NULL
)
RETURNS TABLE (
  training_note_id    uuid,
  body_measurement_id uuid,
  sessions_used       integer,
  sessions_purchased  integer,
  package_status      text
)
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_org     uuid := (auth.jwt() ->> 'org_id')::uuid;
  v_coach   uuid := (auth.jwt() ->> 'user_id')::uuid;
  v_note_id uuid;
  v_bm_id   uuid;
BEGIN
  IF v_org IS NULL OR v_coach IS NULL THEN
    RAISE EXCEPTION 'log_session requires an authenticated staff session';
  END IF;

  IF p_note_text IS NULL OR btrim(p_note_text) = '' THEN
    RAISE EXCEPTION 'note_text is required';
  END IF;

  -- both-or-neither: a lone weight or lone height is a client bug, not a
  -- valid half-measurement.
  IF (p_weight_kg IS NULL) <> (p_height_cm IS NULL) THEN
    RAISE EXCEPTION 'weight_kg and height_cm must be provided together or both omitted';
  END IF;

  INSERT INTO public.training_notes
    (organization_id, member_id, coach_id, pt_package_id, note_text, session_date)
  VALUES
    (v_org, p_member_id, v_coach, p_pt_package_id, p_note_text,
     COALESCE(p_session_date, CURRENT_DATE))
  RETURNING id INTO v_note_id;

  IF p_weight_kg IS NOT NULL THEN
    INSERT INTO public.body_measurements
      (organization_id, member_id, recorded_by, weight_kg, height_cm, training_note_id)
    VALUES
      (v_org, p_member_id, v_coach, p_weight_kg, p_height_cm, v_note_id)
    RETURNING id INTO v_bm_id;
  END IF;

  RETURN QUERY
    SELECT v_note_id, v_bm_id, p.sessions_used, p.sessions_purchased, p.status
      FROM public.pt_packages p
     WHERE p.id = p_pt_package_id;
END;
$$;

-- VOLATILE (the default) on purpose — it writes, so PostgREST exposes it as
-- POST /rest/v1/rpc/log_session only, never GET.
COMMENT ON FUNCTION public.log_session(uuid, uuid, text, date, numeric, numeric) IS
  'Atomically log one coaching session: a training_notes row plus an optional '
  'linked body_measurements row, in one transaction. SECURITY INVOKER — the '
  'caller''s RLS on both tables is what authorises the write. org/coach come '
  'from the JWT. Returns training_note_id, body_measurement_id, and the '
  'package''s sessions_used / sessions_purchased / status after the '
  'session-count trigger. POST only.';

REVOKE ALL ON FUNCTION public.log_session(uuid, uuid, text, date, numeric, numeric) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.log_session(uuid, uuid, text, date, numeric, numeric) TO authenticated;
