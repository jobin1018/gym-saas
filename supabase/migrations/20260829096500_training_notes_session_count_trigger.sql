-- Every logged session (training_notes INSERT) consumes one slot on its
-- pt_package: sessions_used += 1, and the package auto-completes when the
-- purchased count is reached.
--
-- ============================================================================
-- WHY A TRIGGER, NOT APPLICATION CODE
-- ============================================================================
-- sessions_used has to move in lock-step with the notes that cause it, for
-- every writer, atomically. Doing it in the log_session RPC only would leave
-- a direct training_notes INSERT (still a supported path, and how seed.sql
-- and the rls-test happy-path work) able to log a session without advancing
-- the count. A trigger is the only place the invariant holds unconditionally.
-- SECURITY DEFINER + pinned search_path: same discipline as
-- pt_packages_validate_refs() — it UPDATEs pt_packages, and must not resolve
-- that name through a caller-controlled search_path.
--
-- ============================================================================
-- WHY *AFTER* INSERT, NOT BEFORE
-- ============================================================================
-- Verified against this project's Postgres: for INSERT, the RLS WITH CHECK
-- expression is evaluated AFTER BEFORE-row triggers and BEFORE AFTER-row
-- triggers. tenant_isolation_training_notes' coach WITH CHECK calls
-- pt_active_package_match(), which requires the package status = 'active'.
--
--   * BEFORE trigger: it would flip status to 'completed' first, and then the
--     WITH CHECK for THAT SAME boundary note (the 12th of 12) would see a
--     completed package and reject the note that legitimately finished the
--     package. Wrong.
--   * AFTER trigger: the WITH CHECK has already passed against the still-
--     'active' package; the note row exists; only then does this fire and set
--     the count / status. The boundary note is accepted, and the NEXT note
--     hits a 'completed' package and is rejected by RLS (403). Correct.
--
-- ============================================================================
-- CONCURRENCY — no overshoot at the boundary (requirement: rapid/concurrent
-- inserts near the session-count limit must not push sessions_used past
-- sessions_purchased, and must not let an extra note through)
-- ============================================================================
-- Take a package with sessions_purchased = N, sessions_used = N-1, and two
-- requests T1, T2 inserting a note against it at the same time.
--
--   1. Both RLS WITH CHECK passes: pt_active_package_match() is a plain SELECT
--      (SECURITY DEFINER helper). Under READ COMMITTED, until T1 commits, T2's
--      check still sees status = 'active'. So BOTH note rows get inserted and
--      both AFTER triggers begin.
--   2. This function's first act is
--         SELECT ... FROM pt_packages WHERE id = NEW.pt_package_id FOR UPDATE
--      T1 takes the row lock; T2 BLOCKS there.
--   3. T1 sees sessions_used = N-1 < N, updates to N, status -> 'completed',
--      commits, releases the lock.
--   4. T2 unblocks. FOR UPDATE under READ COMMITTED re-reads the latest
--      committed row: sessions_used = N, status = 'completed'. The guard
--      below (`>= sessions_purchased` / not 'active') RAISEs. T2's exception
--      propagates out of the INSERT statement and rolls the note row back
--      (confirmed: an exception in an AFTER INSERT trigger discards the
--      inserted row).
--
-- Net: exactly one note lands, sessions_used = N exactly, status = 'completed'.
-- The loser gets a clean, defined error (SQLSTATE P0001 -> PostgREST 400),
-- not a raw check_violation (23514) and not a silent overshoot. The
-- pt_packages_used_lte_purchased CHECK is still there as a last backstop but
-- this guard means the API never reaches it via this path.
--
-- With more than two racers the same argument holds transitively: the
-- FOR UPDATE serialises them one at a time and every request after the one
-- that hits N fails the guard.
-- ============================================================================

CREATE FUNCTION public.training_notes_bump_session_count()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_used      INTEGER;
  v_purchased INTEGER;
  v_status    TEXT;
BEGIN
  SELECT sessions_used, sessions_purchased, status
    INTO v_used, v_purchased, v_status
    FROM public.pt_packages
   WHERE id = NEW.pt_package_id
     FOR UPDATE;                                  -- serialise concurrent bumps

  IF NOT FOUND THEN
    -- training_notes.pt_package_id is NOT NULL and FK'd, so this is
    -- unreachable in practice; fail loud rather than silently skip the count.
    RAISE EXCEPTION 'training_notes.pt_package_id % not found in pt_packages', NEW.pt_package_id;
  END IF;

  IF v_status <> 'active' OR v_used >= v_purchased THEN
    -- Reachable only as the race-loser described in the header: RLS let this
    -- note in against a package that a concurrent request has since filled.
    RAISE EXCEPTION 'pt_package % is not accepting new sessions (status %, % of % used)',
      NEW.pt_package_id, v_status, v_used, v_purchased;
  END IF;

  UPDATE public.pt_packages
     SET sessions_used = v_used + 1,
         status = CASE WHEN v_used + 1 >= v_purchased THEN 'completed' ELSE status END
   WHERE id = NEW.pt_package_id;

  RETURN NULL;                                    -- AFTER trigger: return value ignored
END;
$$;

-- Trigger functions are invoked by the executor, not called by a role, so no
-- EXECUTE grant is needed — and every role's default EXECUTE is revoked, same
-- as pt_packages_validate_refs().
REVOKE ALL ON FUNCTION public.training_notes_bump_session_count() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.training_notes_bump_session_count() FROM anon, authenticated, service_role;

CREATE TRIGGER trg_training_notes_bump_session_count
  AFTER INSERT ON public.training_notes
  FOR EACH ROW EXECUTE FUNCTION public.training_notes_bump_session_count();
