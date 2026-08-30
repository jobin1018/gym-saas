-- pt_packages.duration_months: match the sanity bound now on
-- memberships.duration_months (1..36), keep it a free integer.
--
-- ============================================================================
-- WHY THIS IS SMALL
-- ============================================================================
-- pt_packages.duration_months (20260829098500) is ALREADY a free integer
-- input, not a fixed dropdown concept — front desk types a number and the
-- BEFORE INSERT trigger derives sessions_purchased = duration_months *
-- sessions_per_month from it. So the model correction the user asked for
-- ("same fix if pt_packages has duration as a fixed/dropdown concept") is
-- already satisfied here; nothing structural changes.
--
-- The only gap was the sanity bound: 20260829098500 used CHECK (> 0), which
-- allows a fat-fingered 600. Bring it in line with
-- memberships.duration_months's 1..36 (three years) — a data-entry guard, not
-- a product limit. sessions_per_month keeps its plain CHECK (> 0): the user
-- only asked for a bound on duration.
--
-- No grants / RLS / trigger changes — pt_packages_derive_sessions and
-- pt_packages_validate_refs are untouched and unaffected by tightening a
-- CHECK on a column neither of them constrains.
-- ============================================================================

ALTER TABLE public.pt_packages DROP CONSTRAINT pt_packages_duration_months_check;
ALTER TABLE public.pt_packages
  ADD CONSTRAINT pt_packages_duration_months_check
    CHECK (duration_months BETWEEN 1 AND 36);
