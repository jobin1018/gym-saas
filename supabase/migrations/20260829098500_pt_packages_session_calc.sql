-- pt_packages: session count is entered as duration_months + sessions_per_month
-- and DERIVED (sessions_purchased = duration_months * sessions_per_month),
-- but still OVERRIDABLE.
--
-- ============================================================================
-- DERIVED-BUT-OVERRIDABLE: a BEFORE INSERT trigger, not a GENERATED column
-- ============================================================================
-- Requirement: front desk enters the PT package's own duration_months (NOT
-- the member's gym-membership plan duration) and sessions_per_month;
-- sessions_purchased is their product. Two ways to encode that:
--
--   GENERATED ALWAYS AS (duration_months * sessions_per_month) STORED
--     + impossible to be inconsistent, zero code.
--     - CANNOT be overridden, ever. Postgres rejects any user-supplied value
--       for a GENERATED ALWAYS column, so "add one discount session" or "coach
--       negotiated 3 extra" is impossible without faking the inputs.
--     - Backfilling existing rows forces an arbitrary decomposition: a stored
--       "12" could be 1x12, 3x4 or 6x2, and the GENERATED value then LOCKS to
--       whichever split we guessed.
--
--   Plain column + BEFORE INSERT trigger that fills it only when omitted
--     + overridable — supply sessions_purchased explicitly to set any number.
--     + existing rows keep their exact stored sessions_purchased untouched;
--       the two new inputs are backfilled to (1, sessions_purchased) so the
--       product still equals the stored value, with no guessing.
--     - the product relationship is not constraint-enforced after insert.
--       Accepted: that is the price of allowing an override at all.
--
-- Chosen: the trigger. The override path is a real operational need (the
-- prompt calls it out), and a GENERATED column's only real advantage —
-- "can't drift" — is exactly the property that blocks the override. There is
-- deliberately NO CHECK (sessions_purchased = duration_months *
-- sessions_per_month): it would forbid every override and break the backfill
-- for any historical row whose real split wasn't 1xN.
--
-- NOT recomputed on UPDATE: once sessions are being consumed, silently
-- lowering the total (possibly below sessions_used, tripping
-- pt_packages_used_lte_purchased) is worse than making the editor pass an
-- explicit new sessions_purchased. Same spirit as the frontend already
-- warning "editing start_date won't recalculate the renewal date".
--
-- ============================================================================
-- pt_packages_validate_refs() — untouched, still compatible
-- ============================================================================
-- That trigger (20260829091000) only ever reads NEW.coach_id / NEW.member_id
-- / NEW.organization_id. It neither reads nor writes sessions_purchased and is
-- unaffected by these columns. Two BEFORE INSERT triggers now fire on
-- pt_packages; they touch disjoint columns and their order is irrelevant.
--
-- ============================================================================
-- GRANTS / RLS — nothing to change
-- ============================================================================
-- pt_packages has table-wide GRANT SELECT (anon, authenticated) and
-- GRANT INSERT, UPDATE (authenticated) from 20260829092000. Table-scoped, so
-- the two new columns are covered with no further GRANT. tenant_isolation_*
-- policies on pt_packages are row-level (org / assignment) with no column
-- dimension — unaffected.
-- ============================================================================

ALTER TABLE public.pt_packages
  ADD COLUMN duration_months   INTEGER NOT NULL DEFAULT 1 CHECK (duration_months > 0);
ALTER TABLE public.pt_packages
  ADD COLUMN sessions_per_month INTEGER NOT NULL DEFAULT 1 CHECK (sessions_per_month > 0);

-- Backfill so the product equals the already-stored sessions_purchased for
-- every existing row, without inventing a duration/rate split we don't know.
-- (No-op on a fresh `db reset` — seed.sql runs after migrations — but correct
-- for staging/prod where pt_packages rows already exist.)
UPDATE public.pt_packages SET sessions_per_month = sessions_purchased;

CREATE FUNCTION public.pt_packages_derive_sessions()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  -- Fill the derived total ONLY when the caller left it unset. An explicit
  -- sessions_purchased is an intentional override and is kept as-is.
  IF NEW.sessions_purchased IS NULL THEN
    NEW.sessions_purchased := NEW.duration_months * NEW.sessions_per_month;
  END IF;
  RETURN NEW;
END;
$$;

-- Trigger function, executor-invoked — revoke the default PUBLIC EXECUTE, same
-- as pt_packages_validate_refs(). (It touches no tables, so this is hygiene
-- rather than a privilege boundary, but kept identical for consistency.)
REVOKE ALL ON FUNCTION public.pt_packages_derive_sessions() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.pt_packages_derive_sessions() FROM anon, authenticated, service_role;

CREATE TRIGGER trg_pt_packages_derive_sessions
  BEFORE INSERT ON public.pt_packages
  FOR EACH ROW EXECUTE FUNCTION public.pt_packages_derive_sessions();

COMMENT ON COLUMN public.pt_packages.duration_months IS
  'The PT package''s own length in months, independent of the member''s gym '
  'membership plan. Input for sessions_purchased.';
COMMENT ON COLUMN public.pt_packages.sessions_per_month IS
  'Sessions per month. sessions_purchased defaults to duration_months * this '
  'on insert (via trg_pt_packages_derive_sessions) but may be overridden by '
  'supplying sessions_purchased explicitly.';
