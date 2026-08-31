-- Grants for whatsapp-webhook's new owner/coach WhatsApp command handlers.
--
-- ============================================================================
-- WHY THIS IS NEEDED
-- ============================================================================
-- whatsapp-webhook runs as service_role (createAdminClient()). service_role
-- has BYPASSRLS but NOT an automatic SELECT on every table/view — same
-- reasoning as every other grants migration in this project
-- (20260823120000_grant_service_role_send_renewal_reminder.sql). The new
-- REVENUE / TODAY / COACHES / LAPSED / PT / NEW commands read from four
-- objects the function has never touched before:
--
--   training_notes            — COACHES / MYCLIENTS "last session logged",
--                               TODAY "PT sessions logged today"
--   v_daily_revenue_by_source — REVENUE + PT month totals, membership/PT split
--   v_lapsed_members          — LAPSED
--   v_members_pt_status       — PT "members on an active package"
--
-- ============================================================================
-- TENANT SCOPING — the caller does it, NOT these grants
-- ============================================================================
-- v_daily_revenue_by_source / v_lapsed_members / v_members_pt_status are
-- security_invoker=true and carry NO org filter of their own, so a
-- BYPASSRLS service_role reading them sees EVERY org. That is fine here
-- because the webhook resolves (organization_id) from the inbound owner_phone
-- BEFORE any query and filters `.eq("organization_id", <that org>)` on every
-- one of these reads — the same boundary the JWT would enforce for a browser
-- session, applied explicitly server-side. Cross-org isolation is covered by
-- whatsapp-webhook/test.sh.
--
-- ============================================================================
-- v_pt_packages_attention — deliberately NOT granted / NOT used
-- ============================================================================
-- Its WHERE clause is hard-bound to auth.jwt() ->> 'org_id' / 'app_role', so a
-- keyless service_role caller gets zero rows from it no matter what. The
-- ALERTS and PT commands recompute its exact predicate
-- (sessions_remaining <= 2 OR days_until_end <= 7, status = 'active') inline
-- against pt_packages (already granted), scoped to the resolved org. No new
-- view or function is added for this.
-- ============================================================================

GRANT SELECT ON public.training_notes            TO service_role;
GRANT SELECT ON public.v_daily_revenue_by_source TO service_role;
GRANT SELECT ON public.v_lapsed_members          TO service_role;
GRANT SELECT ON public.v_members_pt_status       TO service_role;
