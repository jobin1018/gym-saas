-- Backfill realistic payment history for the Revenue page.
--
-- ============================================================================
-- THIS IS NOT A MIGRATION AND NOT PART OF seed.sql
-- ============================================================================
-- Not tracked in supabase_migrations.schema_migrations, not applied by
-- `supabase db reset`, not applied by `supabase db push`. Run it by hand,
-- once, directly against whichever database needs realistic revenue history
-- (see the psql command at the bottom of this file). Safe to run again later
-- too — see IDEMPOTENCY below — but nothing about it is automatic.
--
-- ============================================================================
-- SAFE AGAINST A DATABASE THAT ALREADY HAS REAL DATA IN IT
-- ============================================================================
-- Unlike seed.sql's version of this same logic (which loops over a fixed
-- '80000000-...' ID prefix that only exists in freshly-seeded local/dev
-- databases), this script makes NO assumption about which organizations,
-- members or memberships exist. It queries whatever is actually in the
-- target database at runtime and only ever INSERTs into `payments` —
-- `organizations`, `users`, `members` and `memberships` are read-only here,
-- never written.
--
-- ============================================================================
-- IDEMPOTENCY — safe to run twice, safe to run against a DB with real history
-- ============================================================================
-- For each membership, if it ALREADY has a `status='success'` payment dated
-- within the target window (the last 65 days — current + previous month,
-- with headroom), this script skips it entirely: no success row, no pending
-- row, no failed row, nothing added for that membership. That covers both
-- "I ran this script before" and "this membership already has real payment
-- history from actual usage" with the same check, on purpose — a membership
-- with genuine recent revenue does not need synthetic revenue layered on top
-- of it either way.
--
-- Belt-and-suspenders on top of that: every idempotency_key/provider_
-- payment_id/razorpay_link_id this script generates is derived from the
-- membership's own UUID (globally unique by construction) under a
-- 'backfill-hist-' / 'backfill_pay_' / 'backfill_link_' prefix that matches
-- nothing else in this codebase (seed.sql uses 'seed-hist-', the real
-- send-renewal-reminder flow uses 'renewal-<membership>-<period_end>') and
-- every INSERT carries `ON CONFLICT (idempotency_key) DO NOTHING` as a
-- backstop in case the skip-check above ever has a gap.
--
-- ============================================================================
-- SCOPE: active/past_due memberships only
-- ============================================================================
-- Backfilling a *recent* successful payment onto a `cancelled` or `expired`
-- membership would read as wrong on the Revenue page (why would a lapsed
-- membership show a payment from this month?), so this script only ever
-- touches memberships whose status is 'active' or 'past_due' — the ones a
-- real payment dated this month or last month is actually plausible for.
-- ============================================================================

BEGIN;

DO $$
DECLARE
  r          RECORD;
  idx        INT := 0;
  n_success  INT := 0;
  n_pending  INT := 0;
  n_failed   INT := 0;
  n_skipped  INT;
BEGIN
  -- Captured BEFORE the loop below inserts anything — otherwise every
  -- membership this run just backfilled would also match "already has a
  -- recent success payment" by the time this count ran, wildly inflating
  -- the reported skip count with rows this very run just created.
  SELECT count(*) INTO n_skipped
    FROM memberships ms
   WHERE ms.status IN ('active', 'past_due')
     AND EXISTS (
           SELECT 1 FROM payments p
            WHERE p.membership_id = ms.id
              AND p.status = 'success'
              AND p.created_at > now() - interval '65 days'
         );

  FOR r IN
    SELECT ms.id AS membership_id, ms.organization_id, ms.status, mp.amount
      FROM memberships ms
      JOIN membership_plans mp ON mp.id = ms.plan_id
     WHERE ms.status IN ('active', 'past_due')
       AND NOT EXISTS (
             SELECT 1 FROM payments p
              WHERE p.membership_id = ms.id
                AND p.status = 'success'
                AND p.created_at > now() - interval '65 days'
           )
     ORDER BY ms.id
  LOOP
    idx := idx + 1;

    -- One historical successful payment, spread across the last ~0-55 days
    -- (current + previous month) rather than clustered on one date, so the
    -- Revenue page's day-by-day chart has real variety.
    INSERT INTO payments (organization_id, membership_id, amount, provider,
                           provider_payment_id, status, idempotency_key,
                           created_at, reconciled_at)
    VALUES (
      r.organization_id, r.membership_id, r.amount, 'razorpay',
      'backfill_pay_' || r.membership_id::text, 'success',
      'backfill-hist-success-' || r.membership_id::text,
      now() - (((idx * 3 + 2) % 55) || ' days')::interval,
      now() - (((idx * 3 + 2) % 55) || ' days')::interval + interval '2 hours'
    )
    ON CONFLICT (idempotency_key) DO NOTHING;
    n_success := n_success + 1;

    -- past_due memberships also get an open pending renewal link, same as
    -- what send-renewal-reminder would have left behind.
    IF r.status = 'past_due' THEN
      INSERT INTO payments (organization_id, membership_id, amount, provider,
                             razorpay_link_id, status, idempotency_key, created_at)
      VALUES (
        r.organization_id, r.membership_id, r.amount, 'razorpay',
        'backfill_link_' || r.membership_id::text, 'pending',
        'backfill-hist-pending-' || r.membership_id::text,
        now() - interval '2 days'
      )
      ON CONFLICT (idempotency_key) DO NOTHING;
      n_pending := n_pending + 1;
    END IF;

    -- Every 4th membership also gets a failed attempt on record, same ratio
    -- as seed.sql's version, for realistic variety.
    IF idx % 4 = 0 THEN
      INSERT INTO payments (organization_id, membership_id, amount, provider,
                             status, idempotency_key, created_at)
      VALUES (
        r.organization_id, r.membership_id, r.amount, 'razorpay',
        'failed', 'backfill-hist-failed-' || r.membership_id::text,
        now() - interval '5 days'
      )
      ON CONFLICT (idempotency_key) DO NOTHING;
      n_failed := n_failed + 1;
    END IF;
  END LOOP;

  RAISE NOTICE 'backfill_payment_history: % success, % pending, % failed inserted; % membership(s) already had recent history and were skipped.',
    n_success, n_pending, n_failed, n_skipped;
END $$;

COMMIT;
