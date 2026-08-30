-- v_pt_packages_attention — PT packages the owner should look at: running low
-- on sessions, or near their expected end.
--
-- ============================================================================
-- DASHBOARD DATA, NOT A SCHEDULED SEND (for this pass)
-- ============================================================================
-- The ask was "a scheduled check that flags PT packages within ~7 days of
-- ending or with 1-2 sessions left, and surfaces it to the owner — WhatsApp
-- message OR queryable data, tell me which is realistic now."
--
-- This is a live VIEW: no cron, no function, no scheduling, no idempotency
-- ledger, no failure-logging. It is computed on query and is exactly the data
-- a future WhatsApp job would select from, so it is the foundation for that
-- fast-follow rather than throwaway. A WhatsApp alert additionally needs an
-- APPROVED Meta template (this project only sends approved templates —
-- renewal_reminder, payment_confirmation, daily_owner_brief; free-form sends
-- are flagged TODO(meta)), and template approval is a multi-day Meta review.
-- Out of scope for "before demo"; the recommendation is: ship this view now,
-- add a block to daily-owner-brief (or a sibling cron) that reads it and
-- sends once the pt_package template is approved.
--
-- ============================================================================
-- FLAGGING RULE
-- ============================================================================
--   low_sessions   : sessions_purchased - sessions_used <= 2   (and > -1)
--   expiring_soon  : (start_date + duration_months) is <= 7 days away,
--                    OR already past while the package is still 'active'
--                    (running long / needs closing out or extending)
-- A row appears if EITHER is true. Both booleans are exposed so the dashboard
-- can label/sort; days_until_end and sessions_remaining are exposed raw.
-- status = 'active' only — a completed/cancelled package needs no attention.
--
-- ============================================================================
-- DEFINER VIEW, owner-scoped in the WHERE — same pattern as coaches_directory
-- ============================================================================
-- It JOINs public.users (for the coach name), and `authenticated` has NO
-- grant on users (pin_hash). A security_invoker view would therefore fail
-- closed for everyone. So it runs with definer rights (like coaches_directory
-- / organizations_for_client) and does its OWN scoping in the WHERE:
-- organization_id = the JWT's org_id AND app_role = 'owner'. A non-owner
-- session simply gets zero rows. Grant is to `authenticated` only — no
-- pre-login use, and it is owner-facing. Widening to front_desk later is one
-- predicate.
-- ============================================================================

CREATE VIEW public.v_pt_packages_attention AS
SELECT
  p.id,
  p.organization_id,
  p.member_id,
  p.coach_id,
  m.name  AS member_name,
  m.phone AS member_phone,
  u.name  AS coach_name,
  p.goal,
  p.sessions_purchased,
  p.sessions_used,
  (p.sessions_purchased - p.sessions_used)                                        AS sessions_remaining,
  p.start_date,
  (p.start_date + make_interval(months => p.duration_months))::date               AS expected_end_date,
  ((p.start_date + make_interval(months => p.duration_months))::date - CURRENT_DATE) AS days_until_end,
  ((p.sessions_purchased - p.sessions_used) <= 2)                                  AS low_sessions,
  (((p.start_date + make_interval(months => p.duration_months))::date - CURRENT_DATE) <= 7) AS expiring_soon
FROM public.pt_packages p
JOIN public.members m ON m.id = p.member_id
JOIN public.users   u ON u.id = p.coach_id
WHERE p.organization_id = (auth.jwt() ->> 'org_id')::uuid
  AND (auth.jwt() ->> 'app_role') = 'owner'
  AND p.status = 'active'
  AND (
    (p.sessions_purchased - p.sessions_used) <= 2
    OR ((p.start_date + make_interval(months => p.duration_months))::date - CURRENT_DATE) <= 7
  );

COMMENT ON VIEW public.v_pt_packages_attention IS
  'Active PT packages low on sessions (<=2 left) or at/near their expected '
  'end (<=7 days, or overdue). Owner-only, org-scoped in the WHERE via '
  'auth.jwt() (definer view — it joins users). Dashboard data; the WhatsApp '
  'alert is a fast-follow pending a Meta template.';

GRANT SELECT ON public.v_pt_packages_attention TO authenticated;
