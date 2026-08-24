-- Grants + rate-limit functions for the staff-login Edge Function.
--
-- WHY THIS IS NEEDED: same reasoning as every other grants migration in this
-- project (see 20260823120000_grant_service_role_send_renewal_reminder.sql) —
-- service_role has BYPASSRLS, but table privileges are separate from RLS, and
-- `public.users` has had ZERO grants to any role until now (confirmed via
-- `\d users` and grepping every prior migration). This is the first.
--
-- NOTE ON WHAT IS *NOT* GRANTED: UPDATE on `users` is COLUMN-SCOPED to
-- auth_user_id only. staff-login bootstraps the Supabase Auth bridge for a
-- user the first time they log in — it never touches pin_hash, role, name or
-- phone. Withholding those columns is what keeps "staff-login cannot change
-- who someone is or what they can do" enforced by the database rather than by
-- convention, same discipline as the payments-INSERT-only note in the
-- send-renewal-reminder grants migration.

GRANT SELECT ON public.users TO service_role;
GRANT UPDATE (auth_user_id) ON public.users TO service_role;

-- The outbound audit/rate-limit ledger. INSERT for every attempt, SELECT for
-- the lockout check. Direct table access is intentionally NOT granted beyond
-- this — see the two functions below, which are the only sanctioned way in.
GRANT SELECT, INSERT ON public.login_attempts TO service_role;

-- ---------------------------------------------------------------------------
-- Rate limiting, in Postgres rather than in the Edge Function
-- ---------------------------------------------------------------------------
-- Two round trips from JS (read "how many recent failures", then decide, then
-- write) would compute "now - 15 minutes" against the CALLER's clock and
-- compare it to rows timestamped by the DATABASE's clock — a real clock-skew
-- bug class this avoids by keeping every comparison inside one Postgres
-- statement. It also lets an advisory lock serialize concurrent attempts for
-- the same (org, phone), which JS-side query-builder calls cannot do at all.
--
-- FIXED WINDOW, NOT A RENEWING ONE: locked_until is anchored to the OLDEST of
-- the most recent 5 failures, not the newest. A version that renews on every
-- further attempt is a free, unauthenticated DoS — one dummy request every 14
-- minutes would keep a real staff account locked out indefinitely, without
-- ever guessing a PIN, because inserting a login_attempts row costs the
-- attacker nothing. So a request rejected purely because the account is
-- ALREADY locked does not call staff_login_record_attempt() at all (see
-- staff-login/index.ts) — there is nothing to record, since no PIN was
-- evaluated.
CREATE OR REPLACE FUNCTION public.staff_login_lockout_status(
  p_organization_id UUID,
  p_phone TEXT
)
RETURNS TABLE(locked BOOLEAN, locked_until TIMESTAMPTZ)
LANGUAGE plpgsql
SECURITY INVOKER
AS $$
DECLARE
  v_last_success  TIMESTAMPTZ;
  v_cutoff        TIMESTAMPTZ;
  v_oldest_of_5   TIMESTAMPTZ;
  v_count         INT;
BEGIN
  -- Serializes concurrent lockout checks/writes for the same (org, phone) —
  -- narrows, though does not fully close, a burst-of-concurrent-requests race
  -- (PIN verification itself happens in JS, between this call and
  -- staff_login_record_attempt(), which no in-database lock can span without
  -- moving bcrypt compare into SQL). Accepted as a known limitation: this is
  -- an internal front-desk tool, not an internet-facing target with the
  -- concurrent-connection budget to exploit that gap meaningfully.
  PERFORM pg_advisory_xact_lock(hashtext(p_organization_id::text || ':' || p_phone)::bigint);

  SELECT max(attempted_at) INTO v_last_success
    FROM login_attempts
   WHERE organization_id = p_organization_id AND phone = p_phone AND success = true;

  -- A successful login resets the counter: failures before the last success
  -- never count, regardless of how recent they were.
  v_cutoff := greatest(
    coalesce(v_last_success, '-infinity'::timestamptz),
    now() - interval '15 minutes'
  );

  SELECT count(*), min(attempted_at) INTO v_count, v_oldest_of_5
    FROM (
      SELECT attempted_at
        FROM login_attempts
       WHERE organization_id = p_organization_id
         AND phone = p_phone
         AND success = false
         AND attempted_at > v_cutoff
       ORDER BY attempted_at DESC
       LIMIT 5
    ) recent_failures;

  IF v_count >= 5 THEN
    RETURN QUERY SELECT true, v_oldest_of_5 + interval '15 minutes';
  ELSE
    RETURN QUERY SELECT false, NULL::timestamptz;
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.staff_login_record_attempt(
  p_organization_id UUID,
  p_phone TEXT,
  p_success BOOLEAN
)
RETURNS void
LANGUAGE plpgsql
SECURITY INVOKER
AS $$
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext(p_organization_id::text || ':' || p_phone)::bigint);

  INSERT INTO login_attempts (organization_id, phone, success)
  VALUES (p_organization_id, p_phone, p_success);
END;
$$;

-- PostgREST exposes every function in the `public` schema as
-- /rest/v1/rpc/<name>, and Postgres's default EXECUTE grant is TO PUBLIC —
-- which every role, anon included, inherits. Without the revokes below, an
-- anon-key caller could invoke staff_login_lockout_status() directly over
-- REST for any (organization_id, phone) pair, bypassing the Edge Function
-- entirely and getting a free lockout-status oracle. Same pattern as
-- trigger_renewal_scan()'s revoke in 20260823130500_schedule_renewal_scan_cron.sql.
REVOKE ALL ON FUNCTION public.staff_login_lockout_status(uuid, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.staff_login_lockout_status(uuid, text) FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION public.staff_login_lockout_status(uuid, text) TO service_role;

REVOKE ALL ON FUNCTION public.staff_login_record_attempt(uuid, text, boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.staff_login_record_attempt(uuid, text, boolean) FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION public.staff_login_record_attempt(uuid, text, boolean) TO service_role;
