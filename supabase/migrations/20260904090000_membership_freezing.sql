-- Membership freezing — pause a member's billing/renewal cycle for N days
-- without losing paid time.
--
-- ============================================================================
-- THE MECHANIC
-- ============================================================================
-- memberships.status gains 'frozen'. While frozen, current_period_end is
-- UNCHANGED — the renewal clock is simply not read while status <> 'active'
-- (renewal-scan and mark-overdue's overdue-transition query both already
-- whitelist/require status IN ('active','past_due') — see the note below,
-- no code change was needed there for this to be true). The date only moves
-- when the freeze ENDS, by exactly the number of days the membership was
-- actually frozen:
--
--   auto-unfreeze (frozen_until <= today, mark-overdue's daily run):
--     current_period_end += days              -- the ORIGINALLY REQUESTED count
--   manual early unfreeze (before frozen_until, unfreeze_membership()):
--     current_period_end += (today - frozen_from)   -- ACTUAL days elapsed
--
-- These look like two different rules; they are the same rule evaluated at
-- two different moments. "Days actually frozen" IS frozen_until - frozen_from
-- when the freeze runs its full course (which is what "days" was computed
-- from at creation time), and IS today - frozen_from when it is cut short.
-- The auto-unfreeze path is deliberately pinned to the STORED `days` value
-- rather than recomputing it from calendar time at the moment mark-overdue
-- happens to run, so a delayed cron (the job was down for a day, a deploy
-- was mid-flight) can never credit a member more or fewer days than they
-- were promised — the credited amount is decided once, at freeze time, not
-- at whatever wall-clock instant the batch job gets to it.
--
-- ============================================================================
-- WHICH membership_freezes ROW GOVERNS A CURRENTLY-FROZEN MEMBERSHIP
-- ============================================================================
-- freeze_membership() requires status = 'active' as a precondition, so a
-- membership can only ever be inside ONE frozen episode at a time. That makes
-- "the most recent membership_freezes row for this membership_id" an
-- unambiguous answer for "which freeze put it in this state" — regardless of
-- how many OLDER, already-resolved freeze/unfreeze cycles exist for the same
-- membership. reactivated_at is set ONLY on a manual early end (per the
-- requirement); it is deliberately left NULL on an auto-unfreeze, so
-- "reactivated_at IS NULL" does NOT mean "still frozen" — recency (MAX
-- created_at) is the invariant every lookup in this migration relies on, not
-- reactivated_at's nullness. Both freeze_membership() and mark-overdue's
-- auto-unfreeze pass rely on this same rule; keep them in sync if it changes.
--
-- ============================================================================
-- WHY THIS NEEDED NO CHANGE IN renewal-scan OR mark-overdue's OVERDUE LOGIC
-- ============================================================================
-- renewal-scan's SCAN_STATUSES = ["active","past_due"] and mark-overdue's
-- overdue-transition only ever touches status='active' rows — both are
-- WHITELISTS, not blacklists, so 'frozen' (a status neither list names) was
-- already excluded from both the moment it became a legal value. Nothing to
-- skip; there is simply nothing there to match. mark-overdue DOES gain new
-- code — the auto-unfreeze pass itself — see that function for the sequencing
-- reasoning (unfreeze runs BEFORE the overdue scan, in the same invocation).
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. memberships.status gains 'frozen'
-- ---------------------------------------------------------------------------
ALTER TABLE public.memberships DROP CONSTRAINT memberships_status_check;
ALTER TABLE public.memberships ADD CONSTRAINT memberships_status_check
  CHECK (status = ANY (ARRAY['active','past_due','expired','cancelled','frozen']));

-- ---------------------------------------------------------------------------
-- 2. membership_freezes — one row per freeze episode, kept forever (audit trail)
-- ---------------------------------------------------------------------------
CREATE TABLE public.membership_freezes (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES public.organizations(id),
  membership_id   UUID NOT NULL REFERENCES public.memberships(id),
  frozen_from     DATE NOT NULL,
  frozen_until    DATE NOT NULL,
  days            INTEGER NOT NULL CHECK (days >= 1 AND days <= 365),
  reason          TEXT,
  created_by      UUID NOT NULL REFERENCES public.users(id),
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  -- Set ONLY by a manual early end (unfreeze_membership()). Left NULL when a
  -- freeze runs its full course via mark-overdue's auto-unfreeze — see the
  -- header note above for why NULL here does not mean "still in progress".
  reactivated_at  DATE,
  -- Enforced at the DB level, not just in freeze_membership(): frozen_until is
  -- a stored, denormalized function of frozen_from + days, so a bug anywhere
  -- that tries to write an inconsistent triple is rejected outright rather
  -- than silently corrupting the one date every downstream calculation trusts.
  CONSTRAINT membership_freezes_dates_consistent CHECK (frozen_until = frozen_from + days)
);

-- Serves two lookups: "the most recent freeze for membership X" (both RPCs)
-- and mark-overdue's batch "governing freeze per candidate membership".
CREATE INDEX idx_membership_freezes_membership
  ON public.membership_freezes (membership_id, created_at DESC);

COMMENT ON TABLE public.membership_freezes IS
  'Audit trail of freeze episodes. Never deleted or updated except '
  'reactivated_at (set only on a manual early end — see the header of '
  '20260904090000_membership_freezing.sql for the full mechanic and the '
  '"most recent row governs" lookup rule both RPCs and mark-overdue rely on.';

-- ---------------------------------------------------------------------------
-- 3. RLS — same shape as tenant_isolation_memberships: owner org-wide,
--    front_desk scoped to their own location via the membership -> member ->
--    location_id chain. Both freeze_membership() and unfreeze_membership()
--    are SECURITY INVOKER, so this policy is what actually enforces their
--    authorization — the functions trust it rather than re-deriving it.
-- ---------------------------------------------------------------------------
ALTER TABLE public.membership_freezes ENABLE ROW LEVEL SECURITY;

CREATE POLICY tenant_isolation_membership_freezes ON public.membership_freezes
  USING (
    organization_id = (auth.jwt() ->> 'org_id')::uuid
    AND (
      (auth.jwt() ->> 'app_role') = 'owner'
      OR (
        (auth.jwt() ->> 'app_role') = 'front_desk'
        AND EXISTS (
          SELECT 1 FROM public.memberships ms
            JOIN public.members m ON m.id = ms.member_id
           WHERE ms.id = membership_freezes.membership_id
             AND m.location_id = (auth.jwt() ->> 'location_id')::uuid
        )
      )
    )
  )
  WITH CHECK (
    organization_id = (auth.jwt() ->> 'org_id')::uuid
    AND (
      (auth.jwt() ->> 'app_role') = 'owner'
      OR (
        (auth.jwt() ->> 'app_role') = 'front_desk'
        AND EXISTS (
          SELECT 1 FROM public.memberships ms
            JOIN public.members m ON m.id = ms.member_id
           WHERE ms.id = membership_freezes.membership_id
             AND m.location_id = (auth.jwt() ->> 'location_id')::uuid
        )
      )
    )
  );

-- Suspended-org gate, same pattern as every other tenant table
-- (20260902090000_org_status_enforcement.sql) — a suspended org can neither
-- freeze/unfreeze a membership nor read its freeze history.
CREATE POLICY org_not_suspended ON public.membership_freezes
  AS RESTRICTIVE FOR ALL TO public
  USING (public.current_org_active()) WITH CHECK (public.current_org_active());

-- ---------------------------------------------------------------------------
-- 4. freeze_membership() — owner/front_desk RPC, SECURITY INVOKER
-- ---------------------------------------------------------------------------
-- SECURITY INVOKER (no DEFINER): every read and write below runs as the
-- calling session, so tenant_isolation_membership_freezes / _memberships and
-- org_not_suspended apply exactly as they would to a direct client query —
-- same trust model as log_session(). A membership this session cannot see
-- (wrong org, or wrong location for front_desk) and one that genuinely does
-- not exist produce the SAME 'membership_not_found' error on purpose — same
-- "no business probing other tenants/branches" answer staff-manage gives for
-- an out-of-scope target.
CREATE FUNCTION public.freeze_membership(
  p_membership_id uuid,
  p_days integer,
  p_reason text DEFAULT NULL
)
RETURNS TABLE(
  freeze_id uuid, membership_id uuid, frozen_from date, frozen_until date,
  days integer, status text
)
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_org       uuid := (auth.jwt() ->> 'org_id')::uuid;
  v_user      uuid := (auth.jwt() ->> 'user_id')::uuid;
  v_role      text := (auth.jwt() ->> 'app_role');
  v_status    text;
  v_from      date := CURRENT_DATE;
  v_until     date;
  v_freeze_id uuid;
BEGIN
  IF v_org IS NULL OR v_user IS NULL THEN
    RAISE EXCEPTION 'freeze_membership requires an authenticated staff session';
  END IF;

  -- Explicit, not left to RLS to imply: a coach session would already get
  -- zero rows from the SELECT below (tenant_isolation_memberships has no
  -- coach branch on this table), which would read as 'membership_not_found'
  -- — technically harmless but a misleading message for a plain role
  -- restriction (not a tenant-boundary fact worth obscuring). staff-manage
  -- makes the same distinction: explicit for the caller's own role, obscure
  -- only for a queried target's existence/tenant.
  IF v_role NOT IN ('owner', 'front_desk') THEN
    RAISE EXCEPTION 'not_authorized' USING errcode = '42501';
  END IF;

  -- The org_not_suspended RESTRICTIVE policy would fail the SELECT/UPDATE
  -- below anyway; say so plainly instead of surfacing as 'membership_not_found'.
  IF NOT public.current_org_active() THEN
    RAISE EXCEPTION 'organization_suspended' USING errcode = 'P0001';
  END IF;

  IF p_days IS NULL OR p_days < 1 OR p_days > 365 THEN
    RAISE EXCEPTION 'days_invalid' USING DETAIL = '1..365';
  END IF;

  -- Every bare column name below is table-qualified (m.status, not status) on
  -- purpose, not style: RETURNS TABLE's output columns (status, membership_id,
  -- ...) are implicitly in scope as PL/pgSQL variables for the rest of this
  -- function, and several of them share a name with a real column on
  -- memberships/membership_freezes — an unqualified reference is genuinely
  -- ambiguous (42702) between "the OUT parameter" and "the table column",
  -- caught by testing this against a real request, not by inspection.
  SELECT m.status INTO v_status FROM public.memberships m WHERE m.id = p_membership_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'membership_not_found';
  END IF;

  IF v_status <> 'active' THEN
    CASE v_status
      WHEN 'frozen'    THEN RAISE EXCEPTION 'membership_already_frozen';
      WHEN 'past_due'  THEN RAISE EXCEPTION 'membership_past_due';
      WHEN 'expired'   THEN RAISE EXCEPTION 'membership_expired';
      WHEN 'cancelled' THEN RAISE EXCEPTION 'membership_cancelled';
      ELSE                  RAISE EXCEPTION 'membership_not_active';
    END CASE;
  END IF;

  v_until := v_from + p_days;

  INSERT INTO public.membership_freezes
    (organization_id, membership_id, frozen_from, frozen_until, days, reason, created_by)
  VALUES
    (v_org, p_membership_id, v_from, v_until, p_days,
     NULLIF(btrim(COALESCE(p_reason, '')), ''), v_user)
  RETURNING membership_freezes.id INTO v_freeze_id;

  -- Compare-and-set on the write, same discipline as mark-overdue's
  -- transition(): re-checking status='active' here closes the race where two
  -- freeze attempts (or a freeze racing a payment webhook) land at once. A
  -- lost race rolls back the INSERT above too — this whole call is one
  -- transaction, so there is never a freeze row with no matching status flip.
  UPDATE public.memberships m
     SET status = 'frozen'
   WHERE m.id = p_membership_id
     AND m.status = 'active';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'membership_not_active';
  END IF;

  RETURN QUERY SELECT v_freeze_id, p_membership_id, v_from, v_until, p_days, 'frozen'::text;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.freeze_membership(uuid, integer, text) TO authenticated;

-- ---------------------------------------------------------------------------
-- 5. unfreeze_membership() — manual EARLY end. owner/front_desk RPC, SECURITY
--    INVOKER, same trust model as freeze_membership() above.
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.unfreeze_membership(p_membership_id uuid)
RETURNS TABLE(
  freeze_id uuid, membership_id uuid, reactivated_at date,
  days_frozen integer, current_period_end date, status text
)
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_org         uuid := (auth.jwt() ->> 'org_id')::uuid;
  v_role        text := (auth.jwt() ->> 'app_role');
  v_status      text;
  v_freeze_id   uuid;
  v_frozen_from date;
  v_today       date := CURRENT_DATE;
  v_actual_days integer;
  v_new_end     date;
BEGIN
  IF v_org IS NULL OR (auth.jwt() ->> 'user_id') IS NULL THEN
    RAISE EXCEPTION 'unfreeze_membership requires an authenticated staff session';
  END IF;

  IF v_role NOT IN ('owner', 'front_desk') THEN
    RAISE EXCEPTION 'not_authorized' USING errcode = '42501';
  END IF;

  IF NOT public.current_org_active() THEN
    RAISE EXCEPTION 'organization_suspended' USING errcode = 'P0001';
  END IF;

  -- Same table-qualification discipline as freeze_membership() — RETURNS
  -- TABLE's output columns (membership_id, current_period_end, ...) are
  -- otherwise ambiguous against the real table columns of the same name.
  SELECT m.status INTO v_status FROM public.memberships m WHERE m.id = p_membership_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'membership_not_found';
  END IF;

  IF v_status <> 'frozen' THEN
    RAISE EXCEPTION 'membership_not_frozen';
  END IF;

  -- The governing freeze — see the migration header for why "most recent by
  -- created_at" is unambiguous here.
  SELECT mf.id, mf.frozen_from INTO v_freeze_id, v_frozen_from
    FROM public.membership_freezes mf
   WHERE mf.membership_id = p_membership_id
   ORDER BY mf.created_at DESC
   LIMIT 1;

  IF NOT FOUND THEN
    -- Unreachable in practice (status='frozen' with no freeze row is a data
    -- bug, not a caller error) — fail loudly rather than silently no-op.
    RAISE EXCEPTION 'no membership_freezes row found for a frozen membership — data inconsistency'
      USING errcode = 'P0001';
  END IF;

  -- ACTUAL elapsed days, not the originally requested `days` — they were
  -- frozen for less time than planned, so they are credited less. See the
  -- migration header for why this is the same rule as auto-unfreeze's,
  -- evaluated earlier. Clamped at 0 defensively (frozen_from is never in the
  -- future, so this should never actually go negative).
  v_actual_days := GREATEST(0, v_today - v_frozen_from);

  UPDATE public.membership_freezes mf
     SET reactivated_at = v_today
   WHERE mf.id = v_freeze_id;

  UPDATE public.memberships m
     SET status = 'active',
         current_period_end = m.current_period_end + v_actual_days
   WHERE m.id = p_membership_id
     AND m.status = 'frozen'
   RETURNING m.current_period_end INTO v_new_end;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'membership_not_frozen';
  END IF;

  RETURN QUERY SELECT v_freeze_id, p_membership_id, v_today, v_actual_days, v_new_end, 'active'::text;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.unfreeze_membership(uuid) TO authenticated;
