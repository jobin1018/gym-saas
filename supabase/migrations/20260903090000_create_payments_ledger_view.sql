-- v_payments_ledger — a real transactions view for the gym, readable by
-- front_desk (location-scoped) as well as the owner (org-wide).
--
-- ============================================================================
-- DELIBERATE REVERSAL: front_desk can now READ payment history
-- ============================================================================
-- 20260824140500 made `payments` strictly owner-only, with the stated reason
-- "payment history is exactly the kind of financial detail a front-desk PIN
-- should not expose." This migration INTENTIONALLY walks part of that back:
-- front_desk gets a READ path to payment transactions, scoped to their own
-- location exactly like their members / memberships / attendance access.
--
-- Why the reversal is the right call for the new use case:
--   * The desk question this answers is operational, not analytical: "did
--     this member's payment actually go through?" — a front-desk person
--     standing across from a member who just paid needs the txn status and
--     the provider_payment_id to check, without pulling an owner over.
--   * It is READ ONLY and LOCATION SCOPED, and — see the design note below —
--     scoped to EXACTLY this one curated view. front_desk still cannot write
--     a payment, still cannot see another branch's transactions, and still
--     cannot see org-level revenue.
--
-- ============================================================================
-- DESIGN NOTE: DEFINER view, not security_invoker=true — and why that changed
-- ============================================================================
-- The first draft of this migration made v_payments_ledger security_invoker=
-- true (the organizations_for_client pattern) and added a companion FOR
-- SELECT policy widening tenant_isolation_payments to front_desk for their
-- own location, on the reasoning that a security_invoker view can only ever
-- show what the base table's own RLS already allows.
--
-- Testing that against rls-test.sh caught a real, unintended consequence:
-- v_daily_revenue and v_daily_revenue_by_source (the REVENUE-command /
-- dashboard views) are ALSO security_invoker=true over `payments`, with no
-- role check of their own — they rely entirely on tenant_isolation_payments
-- being owner-only. Widening that ONE base policy to reach v_payments_ledger
-- silently widened THOSE views too: a front_desk session went from seeing
-- zero rows in v_daily_revenue_by_source to seeing their location's revenue
-- figures. That is exactly the "front-desk PIN should not expose financial
-- detail" harm 20260824140500 was written to prevent, just reached through a
-- different view — an inconsistency worth resolving differently, not
-- shipping.
--
-- The fix: v_payments_ledger is a DEFINER view instead — the OTHER pattern
-- named for this task, and the one coaches_directory / v_pt_packages_
-- attention already use for exactly this reason (coaches_directory joins
-- `users`, which `authenticated` cannot read directly at all; same shape of
-- problem). It does its OWN row-scoping in its WHERE clause and runs with the
-- view owner's privileges, so it needs no grant or policy change whatsoever
-- on `payments`, `memberships`, `pt_packages` or `members`. The base
-- `payments` table — and everything else built on it, including the revenue
-- views — is UNTOUCHED by this migration. front_desk's new read access is
-- reachable through this one view and nowhere else.
-- ============================================================================
--
-- The member is reached through whichever of payments' two FKs is set
-- (payments_subject_xor guarantees exactly one): membership_id -> memberships
-- -> members, or pt_package_id -> pt_packages -> members. Both of those
-- columns are NOT NULL FKs to members, so COALESCE(ms.member_id, pk.member_id)
-- is always resolvable and the final JOIN to members is a safe INNER JOIN —
-- it never silently drops a payment row.
--
-- Columns beyond the requested set: `id` (stable React key + pagination
-- tiebreak) and `member_id` (click-through to the member). No column masking —
-- owner and front_desk see the same columns; only the ROW set differs.
CREATE VIEW public.v_payments_ledger AS
SELECT
  p.id,
  p.organization_id,
  m.id                                    AS member_id,
  m.name                                  AS member_name,
  m.location_id,
  COALESCE(p.reconciled_at, p.created_at)  AS transaction_date,
  p.amount,
  p.status,
  p.provider,
  p.provider_payment_id,
  CASE
    WHEN p.membership_id IS NOT NULL THEN 'membership'
    ELSE 'personal_training'
  END                                     AS payment_type
FROM public.payments p
LEFT JOIN public.memberships ms ON ms.id = p.membership_id
LEFT JOIN public.pt_packages pk ON pk.id = p.pt_package_id
JOIN public.members m ON m.id = COALESCE(ms.member_id, pk.member_id)
WHERE p.organization_id = (auth.jwt() ->> 'org_id')::uuid
  AND (
    (auth.jwt() ->> 'app_role') = 'owner'
    OR (
      (auth.jwt() ->> 'app_role') = 'front_desk'
      AND m.location_id = (auth.jwt() ->> 'location_id')::uuid
    )
  );

COMMENT ON VIEW public.v_payments_ledger IS
  'Per-transaction payment ledger. DEFINER view (like coaches_directory) that '
  'does its own scoping: owner sees the whole org, front_desk sees only their '
  'own location. Deliberately does NOT rely on payments'' own RLS, so it adds '
  'no read path to payments/v_daily_revenue* for front_desk. payment_type '
  'derives membership vs personal_training from the XOR FK; transaction_date '
  'is reconciled_at, or created_at when not yet reconciled. Paginate with '
  '.range() + count:''exact'', order by transaction_date DESC, id DESC. '
  'Filter server-side on transaction_date / status / payment_type / '
  'location_id. Owner-only, no pre-login use — granted to authenticated only.';

-- No `anon` grant, unlike most views in this project: this one is reachable
-- only with a real staff session (the WHERE is entirely auth.jwt()-driven),
-- and an anon caller has no org_id/app_role claim to match — same as
-- coaches_directory and v_pt_packages_attention, which also grant
-- authenticated only.
GRANT SELECT ON public.v_payments_ledger TO authenticated;
