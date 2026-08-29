-- body_measurements.training_note_id — link a weigh-in to the session it was
-- taken during.
--
-- ============================================================================
-- WHY
-- ============================================================================
-- The coach UI is merging "add note" and "add measurement" into one "log a
-- session" action: one date, an optional note, optional weight/height. When
-- both are entered they describe the SAME session and should be linked, so
-- the session-history view can show "on 3 Aug: <note>, weighed 72.0kg".
--
-- NULLABLE, on purpose: a standalone weigh-in with no note is still valid
-- (a member drops in, gets weighed, no training happened). Those rows keep
-- training_note_id NULL and are simply not counted as sessions — the
-- session-count trigger (20260829094500) fires on training_notes INSERT, not
-- on measurements.
--
-- ON DELETE: none specified => NO ACTION. training_notes has no DELETE grant
-- for anyone (append-only, see 20260829092000), so a note can't be deleted
-- out from under a measurement through the API. If a future admin path ever
-- deletes notes it must clear/repoint this column first — deliberately left
-- as a hard FK error rather than silently nulling history.
--
-- ============================================================================
-- RLS — a SESSION weigh-in is authorised by its NOTE, not by re-checking the
-- package (this is the fix for a real ordering hazard)
-- ============================================================================
-- The unified session logs the note FIRST. If that note is the one that
-- fills the package, the 20260829096500 trigger flips the package to
-- 'completed' before the linked body_measurements INSERT runs — and the
-- coach WITH CHECK from 20260829091500 (pt_active_assignment_exists, active
-- only) would then reject the weigh-in that belongs to that very session,
-- rolling the whole session back. Confirmed against a live request, not
-- hypothesised.
--
-- Fix: widen the coach WITH CHECK with an OR branch — a measurement whose
-- training_note_id points at a note THIS coach already holds for THIS member
-- is authorised by that note's existence. The note itself could only have
-- been created against an active package (its own WITH CHECK, unchanged), so
-- nothing is loosened: a linked weigh-in is exactly as authorised as the
-- session it is part of. STANDALONE weigh-ins (training_note_id NULL) are
-- untouched — still active-assignment only, so a coach still cannot log a
-- fresh measurement for a member whose package has ended.
--
-- pt_note_authorises_measurement() is a SECURITY DEFINER existence check,
-- same shape/discipline as the 20260829091200 helpers (no members <->
-- pt_packages cycle is involved here — training_notes' policy never looks at
-- body_measurements — but a helper keeps it consistent and out of the policy
-- body).
--
-- ============================================================================
-- INTEGRITY — same discipline as pt_packages_validate_refs()
-- ============================================================================
-- A CHECK can't do cross-row lookups and RLS WITH CHECK only guards the
-- PostgREST path. The trigger below closes the gap for every writer
-- (the log_session RPC, a direct insert, seed.sql, psql): if training_note_id
-- is set it MUST point at a note for the same member in the same org.
-- coach_id is deliberately NOT compared — an owner may record a measurement
-- against a coach's note; member + org is the invariant that matters.
-- SECURITY DEFINER + pinned search_path for the same reason as
-- pt_packages_validate_refs() (reads a table `authenticated` isn't granted
-- broad access to, and must not resolve names via a caller search_path).
-- ============================================================================

ALTER TABLE public.body_measurements
  ADD COLUMN training_note_id UUID REFERENCES public.training_notes(id);

COMMENT ON COLUMN public.body_measurements.training_note_id IS
  'The training_notes row for the session this weigh-in belongs to, or NULL '
  'for a standalone measurement. Set by the log_session RPC when a session '
  'includes both a note and a measurement.';

-- Partial index: only linked rows, for the session-history join
-- (training_notes LEFT JOIN body_measurements ON training_note_id).
CREATE INDEX idx_body_measurements_note
  ON public.body_measurements (training_note_id)
  WHERE training_note_id IS NOT NULL;

CREATE FUNCTION public.body_measurements_validate_note_link()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_note_member UUID;
  v_note_org    UUID;
BEGIN
  IF NEW.training_note_id IS NULL THEN
    RETURN NEW;
  END IF;

  SELECT member_id, organization_id INTO v_note_member, v_note_org
    FROM public.training_notes WHERE id = NEW.training_note_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'body_measurements.training_note_id % does not exist in training_notes', NEW.training_note_id;
  END IF;
  IF v_note_member <> NEW.member_id THEN
    RAISE EXCEPTION 'body_measurements.training_note_id % is for member %, not %',
      NEW.training_note_id, v_note_member, NEW.member_id;
  END IF;
  IF v_note_org <> NEW.organization_id THEN
    RAISE EXCEPTION 'body_measurements.training_note_id % is in org %, not %',
      NEW.training_note_id, v_note_org, NEW.organization_id;
  END IF;

  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.body_measurements_validate_note_link() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.body_measurements_validate_note_link() FROM anon, authenticated, service_role;

CREATE TRIGGER trg_body_measurements_validate_note_link
  BEFORE INSERT OR UPDATE OF training_note_id, member_id, organization_id ON public.body_measurements
  FOR EACH ROW EXECUTE FUNCTION public.body_measurements_validate_note_link();

-- ---------------------------------------------------------------------------
-- "Does this coach hold this exact note for this member/org" — authorises a
-- session-linked weigh-in. Deliberately does NOT look at package status: the
-- note's existence already implies it was logged against an active package.
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.pt_note_authorises_measurement(
  p_note uuid, p_member uuid, p_coach uuid, p_org uuid)
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public, pg_temp
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.training_notes tn
     WHERE tn.id = p_note
       AND tn.member_id = p_member
       AND tn.coach_id  = p_coach
       AND tn.organization_id = p_org
  );
$$;

REVOKE ALL ON FUNCTION public.pt_note_authorises_measurement(uuid, uuid, uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.pt_note_authorises_measurement(uuid, uuid, uuid, uuid) TO anon, authenticated;

-- Replace ONLY the WITH CHECK of tenant_isolation_body_measurements — its
-- USING (read) clause is left for 20260829097000 to widen. Coach INSERT now
-- passes when EITHER there is an active assignment (standalone weigh-in) OR
-- the row is linked to a note this coach holds for this member (session
-- weigh-in). owner still cannot INSERT via the API; recorded_by must be the
-- caller.
ALTER POLICY tenant_isolation_body_measurements ON public.body_measurements
  WITH CHECK (
    organization_id = (auth.jwt() ->> 'org_id')::uuid
    AND (auth.jwt() ->> 'app_role') = 'coach'
    AND recorded_by = (auth.jwt() ->> 'user_id')::uuid
    AND (
      public.pt_active_assignment_exists(
        member_id, (auth.jwt() ->> 'user_id')::uuid, (auth.jwt() ->> 'org_id')::uuid)
      OR (
        training_note_id IS NOT NULL
        AND public.pt_note_authorises_measurement(
          training_note_id, member_id,
          (auth.jwt() ->> 'user_id')::uuid, (auth.jwt() ->> 'org_id')::uuid)
      )
    )
  );

-- `authenticated` already holds SELECT + INSERT on body_measurements
-- (20260829092000); the new column needs no additional grant.
