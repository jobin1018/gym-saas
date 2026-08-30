-- Revenue reporting that supports BOTH a combined total AND a
-- membership-vs-PT breakdown.
--
-- ============================================================================
-- THE SHAPE (decision to confirm: combined + breakout, both)
-- ============================================================================
--   v_daily_revenue            — the COMBINED total per org per day. Column
--                                contract unchanged (organization_id, day,
--                                total, payment_count) so Revenue.tsx and any
--                                other consumer keep working untouched. As of
--                                20260829101000 it naturally includes PT
--                                payments (same `payments` table); this
--                                migration additionally makes it count
--                                'manual' payments (cash/UPI recorded at the
--                                desk is real collected revenue — previously
--                                only Razorpay-reconciled 'success' rows
--                                showed, which meant every PT sale and every
--                                cash membership payment was invisible).
--
--   v_daily_revenue_by_source  — the BREAKDOWN: same grouping plus a `source`
--                                column ('membership' | 'pt_package'). The
--                                owner dashboard's split view reads this; sum
--                                its rows for a day and you get exactly
--                                v_daily_revenue's total for that day.
--
-- So: one combined number from v_daily_revenue, the split from
-- v_daily_revenue_by_source, and they reconcile by construction.
--
-- ============================================================================
-- WHY 'manual' NOW COUNTS
-- ============================================================================
-- 'manual' is a first-class payments.status meaning "recorded outside the
-- provider flow" — a cash or UPI payment taken at the desk. It is collected
-- money. The old `status = 'success'` filter excluded it; that was defensible
-- when the only payments were Razorpay membership renewals, but PT packages
-- are paid manually (20260829101000's trigger writes status='manual'), so
-- excluding it would leave PT revenue at zero. Seed has no 'manual' rows, so
-- this widening changes nothing for existing fixtures.
--
-- date_trunc uses COALESCE(reconciled_at, created_at): every 'success' row
-- has reconciled_at (no change for them); a 'manual' row without one falls
-- back to when it was created instead of grouping into a NULL day.
--
-- ============================================================================
-- security_invoker = true on BOTH — same reasoning as 20260826090000
-- ============================================================================
-- The views must enforce payments' own owner-only tenant_isolation_payments
-- policy as the querying session. Without it they would run as the view owner
-- (bypassing RLS) and leak every org's revenue to every authenticated
-- session, front_desk included. anon/authenticated keep the base SELECT grant
-- so the view can re-check that RLS as the caller.
-- ============================================================================

CREATE OR REPLACE VIEW public.v_daily_revenue
WITH (security_invoker = true) AS
SELECT
  organization_id,
  date_trunc('day', COALESCE(reconciled_at, created_at)) AS day,
  SUM(amount)  AS total,
  COUNT(*)     AS payment_count
FROM public.payments
WHERE status IN ('success', 'manual')
GROUP BY organization_id, date_trunc('day', COALESCE(reconciled_at, created_at));

COMMENT ON VIEW public.v_daily_revenue IS
  'Combined collected revenue per org per day (membership + PT, '
  'success + manual). security_invoker=true -> enforces payments'' owner-only '
  'RLS as the querying session. Sums to v_daily_revenue_by_source per day.';

CREATE VIEW public.v_daily_revenue_by_source
WITH (security_invoker = true) AS
SELECT
  organization_id,
  date_trunc('day', COALESCE(reconciled_at, created_at)) AS day,
  CASE WHEN pt_package_id IS NOT NULL THEN 'pt_package' ELSE 'membership' END AS source,
  SUM(amount)  AS total,
  COUNT(*)     AS payment_count
FROM public.payments
WHERE status IN ('success', 'manual')
GROUP BY
  organization_id,
  date_trunc('day', COALESCE(reconciled_at, created_at)),
  (CASE WHEN pt_package_id IS NOT NULL THEN 'pt_package' ELSE 'membership' END);

COMMENT ON VIEW public.v_daily_revenue_by_source IS
  'v_daily_revenue split by source (''membership'' | ''pt_package''). Same '
  'filter and grouping; adds the source dimension for the owner dashboard''s '
  'breakout. security_invoker=true.';

-- v_daily_revenue's grant is preserved by CREATE OR REPLACE; re-assert both
-- for clarity (idempotent). anon included for the same "reach RLS, not the
-- grant wall" reason as every other grant in this project.
GRANT SELECT ON public.v_daily_revenue           TO anon, authenticated;
GRANT SELECT ON public.v_daily_revenue_by_source TO anon, authenticated;
