-- Backend support for a Member Detail "Deactivate" action, requested ahead of
-- building that UI. Three things were asked to be CONFIRMED, and fixed only
-- if the confirmation turned up a real gap. Findings:
--
--   1. memberships.status direct-write access — NOT what was assumed.
--      `authenticated` already has GRANT UPDATE on the whole memberships
--      table (20260824141000_revoke_local_dev_only_policies.sql), and
--      tenant_isolation_memberships (org + front_desk's own location) is the
--      ONLY thing narrowing that write today. There is no column- or
--      value-level restriction at all: an owner or front_desk session can
--      currently PATCH status to ANY of active/past_due/expired/cancelled/
--      frozen directly, not just 'cancelled'. That is MORE open than asked
--      for, not less — the fix here is a NARROWING guard, not a new grant.
--      See section 1 below.
--
--   2. v_members_pt_status / v_payments_ledger filtered by one member_id —
--      the views themselves need no change (both are plain, inlinable views;
--      Postgres pushes an `id = <uuid>` / `member_id = <uuid>` predicate from
--      the client straight through to the underlying tables). What they sit
--      on top of DOES have a real gap: memberships and payments have no
--      index reachable by member_id/membership_id at all — see section 2.
--
--   3. membership_plans.active readability — already fine, no change.
--      `authenticated` holds a table-level GRANT SELECT on membership_plans
--      (20260824141000) with tenant_isolation_plans scoped by organization_id
--      only (no location carve-out — "one plan catalog per org"), and no
--      column-masking view sits in front of it anywhere. Any membership's
--      plan, joined directly or via a PostgREST embed
--      (`memberships?select=*,membership_plans(active,name)`), already
--      exposes `active` to both owner and front_desk. Nothing to do.
--
-- ============================================================================
-- SECTION 1 — narrow memberships.status to 'cancelled' for direct writes
-- ============================================================================
-- The requirement: an owner/front_desk session may set status to 'cancelled'
-- by a direct write (the Deactivate button, once built, does a plain PATCH —
-- no new Edge Function). Every OTHER status value stays system-managed:
-- active<->past_due (mark-overdue), active<-past_due (razorpay-webhook),
-- ->frozen / frozen->active (freeze_membership / unfreeze_membership).
--
-- A CHECK constraint cannot express this — it has no access to OLD.status or
-- to who is writing. A BEFORE UPDATE OF status trigger does.
--
-- WHO GETS THROUGH:
--   * No actual status change (status present in the SET list but equal to
--     the current value) — always a no-op pass. This is the common case: the
--     member edit flow (plan_id / pricing / current_period_end / start_date)
--     never needs to touch status at all, so this guard is invisible to it
--     whether or not status happens to ride along unchanged in the payload.
--   * Any Postgres role with rolbypassrls = true — checked by catalog lookup,
--     not by hardcoding role names. On this Supabase image that is BOTH
--     `service_role` (mark-overdue / renewal-scan / razorpay-webhook, each
--     with its own already-tested state machine) AND, confirmed by querying
--     pg_roles directly, `postgres` itself (rolsuper is FALSE here — a
--     rolsuper-only check would have missed it). Every existing test suite's
--     fixture setup connects as postgres and writes status directly; gating
--     a role that can already bypass RLS (or simply
--     ALTER TABLE ... DISABLE TRIGGER) would be theater, not defense.
--   * A transaction carrying the app.membership_status_managed_write flag —
--     set by freeze_membership() / unfreeze_membership() immediately before
--     their OWN already-validated status UPDATE (see section 3). Those RPCs
--     are SECURITY INVOKER, so they run AS the calling owner/front_desk
--     session — current_user is 'authenticated' for their internal UPDATE
--     too, indistinguishable from a raw client PATCH by role alone. The GUC
--     is transaction-local (set_config(..., is_local => true)), so it cannot
--     leak into a later, unrelated statement on the same pooled connection,
--     and a PostgREST client can never set it itself (GUCs outside the
--     request.* / response.* namespace are not client-settable through
--     PostgREST).
--   * Everything else attempting NEW.status = 'cancelled' specifically.
-- Everything else raises 42501 (PostgREST -> HTTP 403), same convention as
-- freeze_membership's own not_authorized.
-- ============================================================================

CREATE FUNCTION public.guard_membership_status_direct_write()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $function$
BEGIN
  IF NEW.status IS NOT DISTINCT FROM OLD.status THEN
    RETURN NEW;
  END IF;

  IF (SELECT rolbypassrls FROM pg_roles WHERE rolname = current_user) THEN
    RETURN NEW;
  END IF;

  IF current_setting('app.membership_status_managed_write', true) = 'on' THEN
    RETURN NEW;
  END IF;

  IF NEW.status = 'cancelled' THEN
    RETURN NEW;
  END IF;

  RAISE EXCEPTION 'membership_status_system_managed'
    USING DETAIL = format(
      'status can only be set to ''cancelled'' by a direct write (attempted '
      '%L -> %L); every other transition is system-managed', OLD.status, NEW.status),
    ERRCODE = '42501';
END;
$function$;

COMMENT ON FUNCTION public.guard_membership_status_direct_write() IS
  'BEFORE UPDATE OF status guard on memberships: an ordinary authenticated '
  'session may only move status to ''cancelled'' by a direct write. '
  'service_role and any other rolbypassrls role, plus freeze_membership()/ '
  'unfreeze_membership() via the app.membership_status_managed_write flag, '
  'pass through unrestricted. See 20260905090000 header for the full reasoning.';

CREATE TRIGGER guard_membership_status_direct_write
  BEFORE UPDATE OF status ON public.memberships
  FOR EACH ROW
  EXECUTE FUNCTION public.guard_membership_status_direct_write();

-- ---------------------------------------------------------------------------
-- Deciding: cancelling a FROZEN membership — allowed, and the freeze row
-- needs no cleanup.
-- ---------------------------------------------------------------------------
-- ALLOWED: the trigger above places no restriction on OLD.status, only on
-- NEW.status — frozen -> cancelled goes through exactly like active ->
-- cancelled. Reasoning: freezing is a courtesy pause, not a commitment: a
-- member who paused their membership and then decides to leave for good must
-- still be cancellable without first requiring staff to unfreeze them, which
-- would pointlessly credit days back onto current_period_end for a member who
-- is not coming back to use them.
--
-- The membership_freezes row is left EXACTLY as it was — reactivated_at
-- stays NULL, same as an auto-unfreeze. It is not a "reactivation" (the
-- member did not resume), so stamping reactivated_at would misrepresent what
-- happened; the row remains an accurate historical record of "this member
-- was frozen from X to Y", which stays true regardless of what the
-- membership's status later became. No auto-unfreeze risk either:
-- mark-overdue's auto-unfreeze query is `status = 'frozen' AND frozen_until
-- <= today` (see 20260904090000's header on this being a whitelist, not a
-- blacklist) — the moment status flips to 'cancelled' it no longer matches
-- that clause, so a cancelled-while-frozen membership can never be
-- incorrectly reactivated by the daily cron. Nothing to add here; this
-- paragraph is the record of the decision, not a code change.
-- ============================================================================

-- ============================================================================
-- SECTION 2 — indexes: member_id / membership_id lookups had no index at all
-- ============================================================================
-- memberships had idx_memberships_due (organization_id, status,
-- current_period_end) and nothing else — no index reachable by member_id.
-- payments had idx_payments_status (organization_id, status, created_at) and
-- idx_payments_pt_package (pt_package_id, from 20260829101000) — nothing
-- reachable by membership_id. A member detail page hitting
-- v_payments_ledger?member_id=eq.<uuid> (join chain: members -> memberships
-- -> payments) would sequential-scan both tables today. Same leading-
-- organization_id shape as every other composite index in this schema
-- (idx_memberships_due, idx_payments_status, idx_attendance_member,
-- idx_pt_packages_member/coach, idx_members_org_location).
--
-- v_members_pt_status needed nothing new: its two subqueries hit pt_packages
-- via idx_pt_packages_member (organization_id, member_id, status), already
-- leftmost-prefix-satisfied by RLS's own organization_id predicate even when
-- the client's only explicit filter is `id=eq.<uuid>` on the outer view.
-- ============================================================================

CREATE INDEX idx_memberships_member ON public.memberships (organization_id, member_id);
CREATE INDEX idx_payments_membership ON public.payments (organization_id, membership_id);

COMMENT ON INDEX public.idx_memberships_member IS
  'Serves "this member''s membership(s)" lookups — a member detail page, '
  'v_payments_ledger''s join, and the WhatsApp check-in / renewal flows that '
  'already do this lookup today with no supporting index.';
COMMENT ON INDEX public.idx_payments_membership IS
  'Serves "this membership''s payments" — v_payments_ledger''s join path for '
  'a single-member detail page.';

-- ============================================================================
-- SECTION 3 — freeze_membership() / unfreeze_membership(): set the internal-
-- write flag immediately before their own status UPDATE. Re-declared in full
-- (byte-for-byte plus one PERFORM line each) so this file stays the readable
-- source of truth for what they do now — same practice as
-- 20260902090000's re-declaration of custom_access_token_hook.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.freeze_membership(
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

  IF v_role NOT IN ('owner', 'front_desk') THEN
    RAISE EXCEPTION 'not_authorized' USING errcode = '42501';
  END IF;

  IF NOT public.current_org_active() THEN
    RAISE EXCEPTION 'organization_suspended' USING errcode = 'P0001';
  END IF;

  IF p_days IS NULL OR p_days < 1 OR p_days > 365 THEN
    RAISE EXCEPTION 'days_invalid' USING DETAIL = '1..365';
  END IF;

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

  -- NEW: tell the direct-write guard (section 1) this status flip is coming
  -- from a validated RPC, not an unmediated client PATCH. Transaction-local —
  -- resets on its own, nothing to unset.
  PERFORM set_config('app.membership_status_managed_write', 'on', true);

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

CREATE OR REPLACE FUNCTION public.unfreeze_membership(p_membership_id uuid)
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

  SELECT m.status INTO v_status FROM public.memberships m WHERE m.id = p_membership_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'membership_not_found';
  END IF;

  IF v_status <> 'frozen' THEN
    RAISE EXCEPTION 'membership_not_frozen';
  END IF;

  SELECT mf.id, mf.frozen_from INTO v_freeze_id, v_frozen_from
    FROM public.membership_freezes mf
   WHERE mf.membership_id = p_membership_id
   ORDER BY mf.created_at DESC
   LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'no membership_freezes row found for a frozen membership — data inconsistency'
      USING errcode = 'P0001';
  END IF;

  v_actual_days := GREATEST(0, v_today - v_frozen_from);

  UPDATE public.membership_freezes mf
     SET reactivated_at = v_today
   WHERE mf.id = v_freeze_id;

  -- NEW: same flag as freeze_membership above, immediately before the status
  -- UPDATE it protects.
  PERFORM set_config('app.membership_status_managed_write', 'on', true);

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
