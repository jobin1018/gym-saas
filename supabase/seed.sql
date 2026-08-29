-- Local dev seed. Applied automatically by `supabase db reset`
-- (see [db.seed] sql_paths in config.toml). Safe to delete.
--
-- ============================================================================
-- WHAT THIS FILE IS FOR
-- ============================================================================
-- Comprehensive, realistic fixture data for end-to-end manual testing before
-- staging — five orgs across every status/location shape the schema
-- supports, ~32 members spanning every membership state, multi-week payment
-- and attendance history, and a real WhatsApp message history. Every ID,
-- name and phone number documented below as "PRESERVED" is load-bearing for
-- one or more of the 9 test.sh suites in supabase/functions/ and
-- supabase/rls-test.sh — do not change them without re-reading those suites.
-- Everything else here is free to vary.
--
-- ============================================================================
-- WHY 5 ORGANIZATIONS, NOT 4
-- ============================================================================
-- Iron Temple and FlexFit already exist and are individually load-bearing
-- (exact names, plan amounts, member names/phones/PINs) across dozens of
-- assertions. Repurposing or removing either to hit a literal "4 orgs" count
-- would break far more than it's worth, so the 4 status/location categories
-- (single-location active / multi-location active / trial / suspended) are
-- covered by 3 NEW orgs on top of the 2 preserved ones.
--
-- ============================================================================
-- PRESERVED FIXTURES — do not change without checking every test.sh
-- ============================================================================
-- Orgs:      11111111-... Iron Temple Gym (active), 22222222-... FlexFit
--            Studio (active)
-- Locations: aaaaaaaa-... Iron/Indiranagar, bbbbbbbb-... FlexFit/Koramangala
-- Plans:     cccccccc-... Iron "Monthly Unlimited" = 1500.00,
--            dddddddd-... FlexFit "Monthly Studio" = 2000.00
-- Staff:     919000000001 Ravi Krishnan  owner       Iron  pin 1234
--            919000000011 Priya Nair     front_desk  Iron  pin 1111
--            919000000002 Sanjay Mehta   owner       FlexFit  pin 2345
--            919000000012 Divya Shetty   front_desk  FlexFit  pin 2222
-- Members:   919999999999 Asha Menon (e1111111, Iron, active)
--            918888888888 Bharat Rao (e2222222, Iron, past_due)
--            917777777777 Chitra Iyer (e3333333 Iron / e4444444 FlexFit —
--              the existing "member at two orgs" case)
-- Memberships f1111111.../f4444444... — existence/org/member/plan linkage
--            only; status/current_period_end are overwritten by every
--            suite's own reset_state() and are NOT load-bearing.
-- Payments:  a1111111.../a2222222.../a3333333... — idempotency_key
--            (seed-idem-captured/failed/link), provider_payment_id
--            (pay_TEST_CAPTURED/FAILED), razorpay_link_id (plink_TEST_LINK)
--            are load-bearing; status/reconciled_at are self-healed per-suite.
-- Reserved (must never become real rows): f9999999-... (GHOST_MEMBERSHIP),
--            0daded00-...-0000000000ff (GHOST_ORG), phones 919000099999,
--            919000088801, 919000099901, 915555500001.
--
-- ============================================================================
-- NEW: PowerHouse Fitness / Fitline Wellness / Bodyline Gym
-- ============================================================================
-- PowerHouse (33333333..., active) — the first MULTI-LOCATION org in seed
--   data: Whitefield (66666666...) and Jayanagar (77777777...), staff split
--   across both, members at both — exercises the location-scoped RLS built
--   earlier (20260824140500_rewrite_tenant_isolation_policies_for_jwt.sql).
-- Fitline (44444444..., trial) — briefable (daily-owner-brief treats
--   active+trial the same) but visibly different status everywhere else.
-- Bodyline (55555555..., suspended) — NOT briefable. Platform-suspension
--   enforcement isn't wired into RLS yet (open item), but real data now
--   exists ready for when it is.
--
-- Every seeded PIN, for manual login testing via staff-login — bcrypt cost
-- 12, computed with the same npm:bcryptjs library staff-login/index.ts uses
-- at request time (see that function's own docs for why bcrypt over argon2
-- for a 4-digit keyspace):
--   919000000001 Ravi Krishnan    owner       Iron Temple            1234
--   919000000011 Priya Nair       front_desk  Iron Temple            1111
--   918453100001 Kavya Reddy      front_desk  Iron Temple            3101
--   919000000002 Sanjay Mehta     owner       FlexFit Studio         2345
--   919000000012 Divya Shetty     front_desk  FlexFit Studio         2222
--   918453100002 Arjun Nair       front_desk  FlexFit Studio         3102
--   918453100003 Vikram Singh     owner       PowerHouse Fitness     3103
--   918453100004 Neha Kapoor      front_desk  PowerHouse — Whitefield 3104
--   918453100005 Rohan Verma      front_desk  PowerHouse — Jayanagar  3105
--   918453100006 Ananya Das       front_desk  PowerHouse — Whitefield 3106
--   918453100007 Meera Iyer       owner       Fitline Wellness       3107
--   918453100008 Karthik Rao      front_desk  Fitline Wellness       3108
--   918453100008 Karthik Rao      front_desk  PowerHouse (SAME phone, TWO
--                                              orgs — the real dual-org
--                                              staff case for
--                                              staff-lookup-by-phone)      3108
--   918453100009 Pooja Menon      front_desk  Fitline Wellness       3109
--   918453100010 Suresh Babu      owner       Bodyline Gym           3110
--   918453100011 Lakshmi Pillai   front_desk  Bodyline Gym           3111
--   918453100012 Rahul Shah       front_desk  Bodyline Gym           3112
--
-- Payment fixtures for the razorpay-webhook function (unchanged):
--   pay_TEST_CAPTURED  → pending payment on Asha's ACTIVE membership   (capture path)
--   pay_TEST_FAILED    → pending payment on Bharat's PAST_DUE membership (failure path)
--   plink_TEST_LINK    → pending payment with NO provider_payment_id yet,
--                        matched by razorpay_link_id (payment_link.paid path)

BEGIN;

-- ---------------------------------------------------------------------------
-- ORGANIZATIONS
-- ---------------------------------------------------------------------------
INSERT INTO organizations (id, name, owner_phone, status) VALUES
  ('11111111-1111-1111-1111-111111111111', 'Iron Temple Gym',    '919000000001', 'active'),
  ('22222222-2222-2222-2222-222222222222', 'FlexFit Studio',     '919000000002', 'active'),
  ('33333333-3333-3333-3333-333333333333', 'PowerHouse Fitness', '918453100003', 'active'),
  ('44444444-4444-4444-4444-444444444444', 'Fitline Wellness',   '918453100007', 'trial'),
  ('55555555-5555-5555-5555-555555555555', 'Bodyline Gym',       '918453100010', 'suspended');

-- ---------------------------------------------------------------------------
-- LOCATIONS — PowerHouse gets two, everyone else gets one
-- ---------------------------------------------------------------------------
INSERT INTO locations (id, organization_id, name) VALUES
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', '11111111-1111-1111-1111-111111111111', 'Iron Temple — Indiranagar'),
  ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', '22222222-2222-2222-2222-222222222222', 'FlexFit — Koramangala'),
  ('66666666-6666-6666-6666-666666666666', '33333333-3333-3333-3333-333333333333', 'PowerHouse — Whitefield'),
  ('77777777-7777-7777-7777-777777777777', '33333333-3333-3333-3333-333333333333', 'PowerHouse — Jayanagar'),
  ('88888888-8888-8888-8888-888888888888', '44444444-4444-4444-4444-444444444444', 'Fitline — HSR Layout'),
  ('99999999-9999-9999-9999-999999999999', '55555555-5555-5555-5555-555555555555', 'Bodyline — Marathahalli');

-- ---------------------------------------------------------------------------
-- STAFF / OWNER LOGINS
--
-- location_id NULL for owners (not tied to a branch), set for front_desk.
-- PowerHouse's front_desk staff are deliberately split: two at Whitefield,
-- one at Jayanagar — the actual data location-scoped RLS is exercised
-- against. Karthik Rao appears TWICE, same phone, two different orgs (rows
-- 918453100008a/b below) — the real "same phone, different org" staff case,
-- persistent now instead of a throwaway test-only insert.
-- ---------------------------------------------------------------------------
INSERT INTO users (id, organization_id, name, phone, role, location_id, pin_hash) VALUES
  -- Iron Temple Gym
  ('91111111-1111-1111-1111-111111111111', '11111111-1111-1111-1111-111111111111',
   'Ravi Krishnan', '919000000001', 'owner',      NULL,
   '$2a$12$on0RNeDins4a4rqt4Mcpse8sQ/em3Irl1orEyXYomtKV7sH64bpNS'), -- pin 1234
  ('92222222-2222-2222-2222-222222222222', '11111111-1111-1111-1111-111111111111',
   'Priya Nair',    '919000000011', 'front_desk',
   'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
   '$2a$12$z4yhVi.IJU8huu5x/9.tl.bOEfYHoc4nacMxkYZkc4omzCPP9gd7K'), -- pin 1111
  ('90000000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111',
   'Kavya Reddy',   '918453100001', 'front_desk',
   'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
   '$2a$12$0AvZqgUK3y9569oqbJXCX.HeztSPoM2Ef2nJmbVlem4zMmkLfh.K.'), -- pin 3101
  -- FlexFit Studio
  ('93333333-3333-3333-3333-333333333333', '22222222-2222-2222-2222-222222222222',
   'Sanjay Mehta',  '919000000002', 'owner',      NULL,
   '$2a$12$bbAzBvScb.2lMUqcMsPNJOgYLb6BaY1bW0fn9tjjlXkKE1etAQvlK'), -- pin 2345
  ('94444444-4444-4444-4444-444444444444', '22222222-2222-2222-2222-222222222222',
   'Divya Shetty',  '919000000012', 'front_desk',
   'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
   '$2a$12$P2guAJ41at5K/RCytsI8zevhRcAEX/3S0n0xfbWPqGBqY6zU21HOi'), -- pin 2222
  ('90000000-0000-0000-0000-000000000002', '22222222-2222-2222-2222-222222222222',
   'Arjun Nair',    '918453100002', 'front_desk',
   'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
   '$2a$12$9z9Vxj/D1VaetzLxZiExZelTbcWsyS3EiUvAkQgwhyYhKDuLmQf5.'), -- pin 3102
  -- PowerHouse Fitness (multi-location)
  ('90000000-0000-0000-0000-000000000003', '33333333-3333-3333-3333-333333333333',
   'Vikram Singh',  '918453100003', 'owner',      NULL,
   '$2a$12$G/UCH40ioF.YwlnyMWk9rORjl9QHLO8Se59ly2UEkFQkqkm/MP2..'), -- pin 3103
  ('90000000-0000-0000-0000-000000000004', '33333333-3333-3333-3333-333333333333',
   'Neha Kapoor',   '918453100004', 'front_desk',
   '66666666-6666-6666-6666-666666666666',
   '$2a$12$PbTOvRrsvj3imTVdfMo5ueU7MLYLLBDz0tU75BNjeoATIFUEtpdWC'), -- pin 3104
  ('90000000-0000-0000-0000-000000000005', '33333333-3333-3333-3333-333333333333',
   'Rohan Verma',   '918453100005', 'front_desk',
   '77777777-7777-7777-7777-777777777777',
   '$2a$12$D2WP5v9JscRVv5JD.dW7rOig.ZPiCXzr4DbObBZKDBhoKuGkih.76'), -- pin 3105
  ('90000000-0000-0000-0000-000000000006', '33333333-3333-3333-3333-333333333333',
   'Ananya Das',    '918453100006', 'front_desk',
   '66666666-6666-6666-6666-666666666666',
   '$2a$12$pwuzOK.kqGbto70KsigzF.onADLqGNzNW5.4Y81IWYw8rEa/4nk9.'), -- pin 3106
  ('90000000-0000-0000-0000-000000000013', '33333333-3333-3333-3333-333333333333',
   'Karthik Rao',   '918453100008', 'front_desk',
   '66666666-6666-6666-6666-666666666666',
   '$2a$12$6WPKDlwt13jrLj5lPGgWUe.9z7l7/TEipnoORiGq3jN9UafGEC80m'), -- pin 3108 (also at Fitline, below)
  -- Fitline Wellness (trial)
  ('90000000-0000-0000-0000-000000000007', '44444444-4444-4444-4444-444444444444',
   'Meera Iyer',    '918453100007', 'owner',      NULL,
   '$2a$12$F4eY8qyrfGgTdIOCCjvkFepJ2CNNKYZQpPEz1QI7IHiRCqW0ReFKC'), -- pin 3107
  ('90000000-0000-0000-0000-000000000008', '44444444-4444-4444-4444-444444444444',
   'Karthik Rao',   '918453100008', 'front_desk',
   '88888888-8888-8888-8888-888888888888',
   '$2a$12$6WPKDlwt13jrLj5lPGgWUe.9z7l7/TEipnoORiGq3jN9UafGEC80m'), -- pin 3108 (SAME phone as PowerHouse row above)
  ('90000000-0000-0000-0000-000000000009', '44444444-4444-4444-4444-444444444444',
   'Pooja Menon',   '918453100009', 'front_desk',
   '88888888-8888-8888-8888-888888888888',
   '$2a$12$VZkks46o2kAxWY6/ytogq.NeQaF3v5jQXB6G9WGVKSIdiKgC4JZbm'), -- pin 3109
  -- Bodyline Gym (suspended)
  ('90000000-0000-0000-0000-000000000010', '55555555-5555-5555-5555-555555555555',
   'Suresh Babu',   '918453100010', 'owner',      NULL,
   '$2a$12$bsLJHnocy5oyZ7nrbDL1AuVOI174lZe3yYLX70poXIFQtZRO0iMp2'), -- pin 3110
  ('90000000-0000-0000-0000-000000000011', '55555555-5555-5555-5555-555555555555',
   'Lakshmi Pillai', '918453100011', 'front_desk',
   '99999999-9999-9999-9999-999999999999',
   '$2a$12$37ENowRY8O07Wnb5HlmOY.kyZBe3Arj.kQsUoaUCvnW0glEgpM/wC'), -- pin 3111
  ('90000000-0000-0000-0000-000000000012', '55555555-5555-5555-5555-555555555555',
   'Rahul Shah',    '918453100012', 'front_desk',
   '99999999-9999-9999-9999-999999999999',
   '$2a$12$0bF5lEd9darW8oMgQkcuz.9QTBgdog99GBndRA2SSIkEzVQfuDQBa'); -- pin 3112

-- ---------------------------------------------------------------------------
-- MEMBERSHIP PLANS — every org gets at least 2 tiers now. cccccccc/dddddddd
-- keep their exact preserved amounts (1500.00 / 2000.00); everything else is
-- a fresh plan id.
-- ---------------------------------------------------------------------------
INSERT INTO membership_plans (id, organization_id, name, amount) VALUES
  ('cccccccc-cccc-cccc-cccc-cccccccccccc', '11111111-1111-1111-1111-111111111111', 'Monthly Unlimited', 1500.00),
  ('b0000000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'Basic',             1200.00),
  ('dddddddd-dddd-dddd-dddd-dddddddddddd', '22222222-2222-2222-2222-222222222222', 'Monthly Studio',    2000.00),
  ('b0000000-0000-0000-0000-000000000002', '22222222-2222-2222-2222-222222222222', 'Premium',           2800.00),
  ('b0000000-0000-0000-0000-000000000003', '33333333-3333-3333-3333-333333333333', 'Basic',             1400.00),
  ('b0000000-0000-0000-0000-000000000004', '33333333-3333-3333-3333-333333333333', 'Premium',           2500.00),
  ('b0000000-0000-0000-0000-000000000005', '44444444-4444-4444-4444-444444444444', 'Basic',             1000.00),
  ('b0000000-0000-0000-0000-000000000006', '44444444-4444-4444-4444-444444444444', 'Premium',           1800.00),
  ('b0000000-0000-0000-0000-000000000007', '55555555-5555-5555-5555-555555555555', 'Basic',             1300.00),
  ('b0000000-0000-0000-0000-000000000008', '55555555-5555-5555-5555-555555555555', 'Premium',           2200.00);

-- ---------------------------------------------------------------------------
-- MEMBERS — preserved 4 (Asha/Bharat/Chitra×2) plus 24 new, spread across
-- every membership state the schema supports. Phones use a clean
-- 9184532000NN range — deliberately NOT a repeating-digit pattern
-- (919999999999-style), since Razorpay's test-mode API has been seen
-- rejecting those for real payment-link customer.contact fields.
-- ---------------------------------------------------------------------------
INSERT INTO members (id, organization_id, location_id, name, phone, whatsapp_opt_in, source) VALUES
  -- Iron Temple Gym (preserved)
  ('e1111111-1111-1111-1111-111111111111', '11111111-1111-1111-1111-111111111111',
   'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'Asha Menon',   '919999999999', true, 'manual'),
  ('e2222222-2222-2222-2222-222222222222', '11111111-1111-1111-1111-111111111111',
   'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'Bharat Rao',   '918888888888', true, 'manual'),
  ('e3333333-3333-3333-3333-333333333333', '11111111-1111-1111-1111-111111111111',
   'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'Chitra Iyer',  '917777777777', true, 'manual'),
  -- Iron Temple Gym (new)
  ('80000000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111',
   'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'Deepak Kumar',  '918453200001', true,  'manual'),
  ('80000000-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111',
   'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'Sneha Gupta',   '918453200002', true,  'whatsapp_self'),
  ('80000000-0000-0000-0000-000000000003', '11111111-1111-1111-1111-111111111111',
   'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'Manoj Tiwari',  '918453200003', true,  'whatsapp_self'),
  ('80000000-0000-0000-0000-000000000004', '11111111-1111-1111-1111-111111111111',
   'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'Ritu Sharma',   '918453200004', true,  'manual'),
  ('80000000-0000-0000-0000-000000000005', '11111111-1111-1111-1111-111111111111',
   'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'Ajay Mishra',   '918453200005', false, 'manual'),
  ('80000000-0000-0000-0000-000000000006', '11111111-1111-1111-1111-111111111111',
   'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'Pooja Agarwal', '918453200006', true,  'manual'),
  -- FlexFit Studio (preserved)
  ('e4444444-4444-4444-4444-444444444444', '22222222-2222-2222-2222-222222222222',
   'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'Chitra Iyer',  '917777777777', true, 'manual'),
  -- FlexFit Studio (new)
  ('80000000-0000-0000-0000-000000000007', '22222222-2222-2222-2222-222222222222',
   'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'Rakesh Iyer',   '918453200007', true,  'whatsapp_self'),
  ('80000000-0000-0000-0000-000000000008', '22222222-2222-2222-2222-222222222222',
   'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'Anjali Desai',  '918453200008', true,  'whatsapp_self'),
  ('80000000-0000-0000-0000-000000000009', '22222222-2222-2222-2222-222222222222',
   'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'Vivek Nair',    '918453200009', true,  'manual'),
  ('80000000-0000-0000-0000-000000000010', '22222222-2222-2222-2222-222222222222',
   'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'Kiran Patel',   '918453200010', false, 'manual'),
  -- PowerHouse Fitness — Whitefield
  ('80000000-0000-0000-0000-000000000011', '33333333-3333-3333-3333-333333333333',
   '66666666-6666-6666-6666-666666666666', 'Amit Verma',    '918453200011', true,  'whatsapp_self'),
  ('80000000-0000-0000-0000-000000000012', '33333333-3333-3333-3333-333333333333',
   '66666666-6666-6666-6666-666666666666', 'Priyanka Shah', '918453200012', true,  'whatsapp_self'),
  ('80000000-0000-0000-0000-000000000013', '33333333-3333-3333-3333-333333333333',
   '66666666-6666-6666-6666-666666666666', 'Rahul Menon',   '918453200013', true,  'manual'),
  -- PowerHouse Fitness — Jayanagar
  ('80000000-0000-0000-0000-000000000014', '33333333-3333-3333-3333-333333333333',
   '77777777-7777-7777-7777-777777777777', 'Sonia Kapoor',  '918453200014', true,  'whatsapp_self'),
  ('80000000-0000-0000-0000-000000000015', '33333333-3333-3333-3333-333333333333',
   '77777777-7777-7777-7777-777777777777', 'Nikhil Rao',    '918453200015', true,  'manual'),
  ('80000000-0000-0000-0000-000000000016', '33333333-3333-3333-3333-333333333333',
   '77777777-7777-7777-7777-777777777777', 'Farah Khan',    '918453200016', false, 'manual'),
  -- Fitline Wellness
  ('80000000-0000-0000-0000-000000000017', '44444444-4444-4444-4444-444444444444',
   '88888888-8888-8888-8888-888888888888', 'Rajesh Pillai',  '918453200017', true,  'whatsapp_self'),
  ('80000000-0000-0000-0000-000000000018', '44444444-4444-4444-4444-444444444444',
   '88888888-8888-8888-8888-888888888888', 'Meenakshi Iyer', '918453200018', true,  'whatsapp_self'),
  ('80000000-0000-0000-0000-000000000019', '44444444-4444-4444-4444-444444444444',
   '88888888-8888-8888-8888-888888888888', 'Suresh Naidu',   '918453200019', true,  'manual'),
  ('80000000-0000-0000-0000-000000000020', '44444444-4444-4444-4444-444444444444',
   '88888888-8888-8888-8888-888888888888', 'Geeta Reddy',    '918453200020', false, 'manual'),
  -- Bodyline Gym
  ('80000000-0000-0000-0000-000000000021', '55555555-5555-5555-5555-555555555555',
   '99999999-9999-9999-9999-999999999999', 'Harish Chandra', '918453200021', true,  'whatsapp_self'),
  ('80000000-0000-0000-0000-000000000022', '55555555-5555-5555-5555-555555555555',
   '99999999-9999-9999-9999-999999999999', 'Nandini Rao',    '918453200022', true,  'manual'),
  ('80000000-0000-0000-0000-000000000023', '55555555-5555-5555-5555-555555555555',
   '99999999-9999-9999-9999-999999999999', 'Vikas Kumar',    '918453200023', false, 'manual'),
  ('80000000-0000-0000-0000-000000000024', '55555555-5555-5555-5555-555555555555',
   '99999999-9999-9999-9999-999999999999', 'Shalini Gupta',  '918453200024', true,  'manual');

-- ---------------------------------------------------------------------------
-- MEMBERSHIPS — explicit ids so payments/attendance fixtures can reference
-- them. f1111111...f4444444... existence/linkage preserved; status/dates on
-- those 4 are NOT load-bearing (every suite's reset_state() overwrites them).
--
-- current_period_end offsets are deliberate:
--   +7 / +3 days  -> renewal-scan's default REMINDER_OFFSET_DAYS (7,3), so
--                    a real scan finds real due members.
--   -1 / -10..-12 / -30+ days -> the "1 day late / ~10 days late / 30+ days
--                    late" past_due spread requested.
--   cancelled/expired dates are cosmetic (those statuses are terminal).
-- ---------------------------------------------------------------------------
INSERT INTO memberships (id, organization_id, member_id, plan_id, status, start_date, current_period_end) VALUES
  -- preserved
  ('f1111111-1111-1111-1111-111111111111', '11111111-1111-1111-1111-111111111111',
   'e1111111-1111-1111-1111-111111111111', 'cccccccc-cccc-cccc-cccc-cccccccccccc',
   'active',   CURRENT_DATE - 10, CURRENT_DATE + 20),
  ('f2222222-2222-2222-2222-222222222222', '11111111-1111-1111-1111-111111111111',
   'e2222222-2222-2222-2222-222222222222', 'cccccccc-cccc-cccc-cccc-cccccccccccc',
   'past_due', CURRENT_DATE - 40, CURRENT_DATE - 10),
  ('f3333333-3333-3333-3333-333333333333', '11111111-1111-1111-1111-111111111111',
   'e3333333-3333-3333-3333-333333333333', 'cccccccc-cccc-cccc-cccc-cccccccccccc',
   'active',   CURRENT_DATE - 5,  CURRENT_DATE + 25),
  ('f4444444-4444-4444-4444-444444444444', '22222222-2222-2222-2222-222222222222',
   'e4444444-4444-4444-4444-444444444444', 'dddddddd-dddd-dddd-dddd-dddddddddddd',
   'active',   CURRENT_DATE - 5,  CURRENT_DATE + 25),
  -- Iron Temple (new)
  ('70000000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111',
   '80000000-0000-0000-0000-000000000001', 'cccccccc-cccc-cccc-cccc-cccccccccccc',
   'active',   CURRENT_DATE - 15, CURRENT_DATE + 45),
  ('70000000-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111',
   '80000000-0000-0000-0000-000000000002', 'b0000000-0000-0000-0000-000000000001',
   'active',   CURRENT_DATE - 23, CURRENT_DATE + 7),
  ('70000000-0000-0000-0000-000000000003', '11111111-1111-1111-1111-111111111111',
   '80000000-0000-0000-0000-000000000003', 'cccccccc-cccc-cccc-cccc-cccccccccccc',
   'active',   CURRENT_DATE - 19, CURRENT_DATE + 11),
  ('70000000-0000-0000-0000-000000000004', '11111111-1111-1111-1111-111111111111',
   '80000000-0000-0000-0000-000000000004', 'b0000000-0000-0000-0000-000000000001',
   'past_due', CURRENT_DATE - 31, CURRENT_DATE - 1),
  ('70000000-0000-0000-0000-000000000005', '11111111-1111-1111-1111-111111111111',
   '80000000-0000-0000-0000-000000000005', 'cccccccc-cccc-cccc-cccc-cccccccccccc',
   'past_due', CURRENT_DATE - 62, CURRENT_DATE - 32),
  ('70000000-0000-0000-0000-000000000006', '11111111-1111-1111-1111-111111111111',
   '80000000-0000-0000-0000-000000000006', 'b0000000-0000-0000-0000-000000000001',
   'cancelled', CURRENT_DATE - 120, CURRENT_DATE - 60),
  -- FlexFit (new)
  ('70000000-0000-0000-0000-000000000007', '22222222-2222-2222-2222-222222222222',
   '80000000-0000-0000-0000-000000000007', 'dddddddd-dddd-dddd-dddd-dddddddddddd',
   'active',   CURRENT_DATE - 15, CURRENT_DATE + 15),
  ('70000000-0000-0000-0000-000000000008', '22222222-2222-2222-2222-222222222222',
   '80000000-0000-0000-0000-000000000008', 'b0000000-0000-0000-0000-000000000002',
   'active',   CURRENT_DATE - 17, CURRENT_DATE + 13),
  ('70000000-0000-0000-0000-000000000009', '22222222-2222-2222-2222-222222222222',
   '80000000-0000-0000-0000-000000000009', 'dddddddd-dddd-dddd-dddd-dddddddddddd',
   'past_due', CURRENT_DATE - 41, CURRENT_DATE - 11),
  ('70000000-0000-0000-0000-000000000010', '22222222-2222-2222-2222-222222222222',
   '80000000-0000-0000-0000-000000000010', 'b0000000-0000-0000-0000-000000000002',
   'expired',  CURRENT_DATE - 150, CURRENT_DATE - 90),
  -- PowerHouse — Whitefield members
  ('70000000-0000-0000-0000-000000000011', '33333333-3333-3333-3333-333333333333',
   '80000000-0000-0000-0000-000000000011', 'b0000000-0000-0000-0000-000000000003',
   'active',   CURRENT_DATE - 10, CURRENT_DATE + 20),
  ('70000000-0000-0000-0000-000000000012', '33333333-3333-3333-3333-333333333333',
   '80000000-0000-0000-0000-000000000012', 'b0000000-0000-0000-0000-000000000004',
   'active',   CURRENT_DATE - 27, CURRENT_DATE + 3),
  ('70000000-0000-0000-0000-000000000013', '33333333-3333-3333-3333-333333333333',
   '80000000-0000-0000-0000-000000000013', 'b0000000-0000-0000-0000-000000000003',
   'past_due', CURRENT_DATE - 31, CURRENT_DATE - 1),
  -- PowerHouse — Jayanagar members
  ('70000000-0000-0000-0000-000000000014', '33333333-3333-3333-3333-333333333333',
   '80000000-0000-0000-0000-000000000014', 'b0000000-0000-0000-0000-000000000004',
   'active',   CURRENT_DATE - 5,  CURRENT_DATE + 25),
  ('70000000-0000-0000-0000-000000000015', '33333333-3333-3333-3333-333333333333',
   '80000000-0000-0000-0000-000000000015', 'b0000000-0000-0000-0000-000000000003',
   'past_due', CURRENT_DATE - 40, CURRENT_DATE - 10),
  ('70000000-0000-0000-0000-000000000016', '33333333-3333-3333-3333-333333333333',
   '80000000-0000-0000-0000-000000000016', 'b0000000-0000-0000-0000-000000000004',
   'cancelled', CURRENT_DATE - 100, CURRENT_DATE - 40),
  -- Fitline
  ('70000000-0000-0000-0000-000000000017', '44444444-4444-4444-4444-444444444444',
   '80000000-0000-0000-0000-000000000017', 'b0000000-0000-0000-0000-000000000005',
   'active',   CURRENT_DATE - 21, CURRENT_DATE + 9),
  ('70000000-0000-0000-0000-000000000018', '44444444-4444-4444-4444-444444444444',
   '80000000-0000-0000-0000-000000000018', 'b0000000-0000-0000-0000-000000000006',
   'active',   CURRENT_DATE - 1,  CURRENT_DATE + 30),
  ('70000000-0000-0000-0000-000000000019', '44444444-4444-4444-4444-444444444444',
   '80000000-0000-0000-0000-000000000019', 'b0000000-0000-0000-0000-000000000005',
   'past_due', CURRENT_DATE - 43, CURRENT_DATE - 13),
  ('70000000-0000-0000-0000-000000000020', '44444444-4444-4444-4444-444444444444',
   '80000000-0000-0000-0000-000000000020', 'b0000000-0000-0000-0000-000000000006',
   'expired',  CURRENT_DATE - 105, CURRENT_DATE - 45),
  -- Bodyline
  ('70000000-0000-0000-0000-000000000021', '55555555-5555-5555-5555-555555555555',
   '80000000-0000-0000-0000-000000000021', 'b0000000-0000-0000-0000-000000000007',
   'active',   CURRENT_DATE - 15, CURRENT_DATE + 15),
  ('70000000-0000-0000-0000-000000000022', '55555555-5555-5555-5555-555555555555',
   '80000000-0000-0000-0000-000000000022', 'b0000000-0000-0000-0000-000000000008',
   'past_due', CURRENT_DATE - 50, CURRENT_DATE - 20),
  ('70000000-0000-0000-0000-000000000023', '55555555-5555-5555-5555-555555555555',
   '80000000-0000-0000-0000-000000000023', 'b0000000-0000-0000-0000-000000000007',
   'cancelled', CURRENT_DATE - 130, CURRENT_DATE - 70),
  ('70000000-0000-0000-0000-000000000024', '55555555-5555-5555-5555-555555555555',
   '80000000-0000-0000-0000-000000000024', 'b0000000-0000-0000-0000-000000000008',
   'expired',  CURRENT_DATE - 160, CURRENT_DATE - 100);

-- ---------------------------------------------------------------------------
-- PAYMENTS
-- ---------------------------------------------------------------------------
-- Preserved fixtures for razorpay-webhook (unchanged).
INSERT INTO payments (id, organization_id, membership_id, amount, provider,
                      provider_payment_id, razorpay_link_id, status, idempotency_key) VALUES
  ('a1111111-1111-1111-1111-111111111111', '11111111-1111-1111-1111-111111111111',
   'f1111111-1111-1111-1111-111111111111', 1500.00, 'razorpay',
   'pay_TEST_CAPTURED', NULL,              'pending', 'seed-idem-captured'),
  ('a2222222-2222-2222-2222-222222222222', '11111111-1111-1111-1111-111111111111',
   'f2222222-2222-2222-2222-222222222222', 1500.00, 'razorpay',
   'pay_TEST_FAILED',   NULL,              'pending', 'seed-idem-failed'),
  ('a3333333-3333-3333-3333-333333333333', '11111111-1111-1111-1111-111111111111',
   'f3333333-3333-3333-3333-333333333333', 1500.00, 'razorpay',
   NULL,                'plink_TEST_LINK', 'pending', 'seed-idem-link');

-- Realistic historical payments for the 24 new memberships: one successful
-- payment each (spread over the past several weeks, so v_daily_revenue has
-- real day-to-day variety instead of one cluster), an open pending link for
-- every past_due member, and a failed attempt on a handful of them. Prefixed
-- 'seed-hist-' (not 'renewal-') deliberately — these simulate PAST activity,
-- not what send-renewal-reminder would generate at runtime, and the prefix
-- keeps them clear of that function's own idempotency-key format.
DO $$
DECLARE
  r   RECORD;
  idx INT := 0;
BEGIN
  FOR r IN
    SELECT ms.id AS membership_id, ms.organization_id, ms.status, mp.amount
    FROM memberships ms
    JOIN membership_plans mp ON mp.id = ms.plan_id
    WHERE ms.id::text LIKE '70000000-0000-0000-0000-0000000000%'
    ORDER BY ms.id
  LOOP
    idx := idx + 1;

    INSERT INTO payments (organization_id, membership_id, amount, provider,
                           provider_payment_id, status, idempotency_key,
                           created_at, reconciled_at)
    VALUES (
      r.organization_id, r.membership_id, r.amount, 'razorpay',
      'seed_hist_pay_' || idx, 'success',
      'seed-hist-success-' || r.membership_id::text,
      now() - ((idx * 3 + 2) || ' days')::interval,
      now() - ((idx * 3 + 2) || ' days')::interval + interval '2 hours'
    );

    IF r.status = 'past_due' THEN
      INSERT INTO payments (organization_id, membership_id, amount, provider,
                             razorpay_link_id, status, idempotency_key, created_at)
      VALUES (
        r.organization_id, r.membership_id, r.amount, 'razorpay',
        'seed_hist_link_' || idx, 'pending',
        'seed-hist-pending-' || r.membership_id::text,
        now() - interval '2 days'
      );
    END IF;

    IF idx % 4 = 0 THEN
      INSERT INTO payments (organization_id, membership_id, amount, provider,
                             status, idempotency_key, created_at)
      VALUES (
        r.organization_id, r.membership_id, r.amount, 'razorpay',
        'failed', 'seed-hist-failed-' || r.membership_id::text,
        now() - interval '5 days'
      );
    END IF;
  END LOOP;
END $$;

-- ---------------------------------------------------------------------------
-- ATTENDANCE — 21 days of check-in history for every active/past_due member
-- (preserved + new), varied frequency per member. Deterministic (modulo-
-- based), not random(), so this file produces the same data on every
-- `supabase db reset` — no flakiness, fully reproducible.
--
-- NOTE: whatsapp-webhook/test.sh's reset_state() TRUNCATEs this table before
-- its own assertions, and it runs first in run-all-tests.sh — so this history
-- exists for manual/Studio browsing and v_lapsed_members, and does not
-- survive (or interact with) the automated suite. That's expected, not a bug.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  r    RECORD;
  idx  INT := 0;
  d    INT;
  step INT;
  ts   TIMESTAMPTZ;
BEGIN
  FOR r IN
    SELECT me.id AS member_id, me.organization_id
    FROM members me
    JOIN memberships ms ON ms.member_id = me.id
    WHERE ms.status IN ('active', 'past_due')
    ORDER BY me.id
  LOOP
    idx  := idx + 1;
    step := (idx % 3) + 1; -- 1 = almost daily, 2 = every other day, 3 = ~twice a week

    FOR d IN 0..20 LOOP
      IF d % step = 0 THEN
        ts := ((CURRENT_DATE - d) + TIME '07:00'
                + ((idx * 37 + d * 11) % 720 || ' minutes')::interval)
              AT TIME ZONE 'Asia/Kolkata';

        INSERT INTO attendance (organization_id, member_id, checked_in_at, source)
        VALUES (
          r.organization_id, r.member_id, ts,
          CASE WHEN (idx + d) % 5 = 0 THEN 'front_desk' ELSE 'whatsapp_self' END
        );
      END IF;
    END LOOP;
  END LOOP;
END $$;

-- ---------------------------------------------------------------------------
-- WHATSAPP MESSAGES — realistic outbound + inbound history.
--
-- Same truncation note as attendance: whatsapp-webhook/test.sh's
-- reset_state() clears this table before any automated assertions run, so
-- this history is for manual testing (and daily-owner-brief's failed-send
-- detection, when run manually / via dry_run) rather than the test suite.
-- ---------------------------------------------------------------------------

-- Outbound renewal_reminder for every new past_due member — one in twenty
-- deliberately 'failed', for daily-owner-brief's failed-send detection to
-- have something real to find on a manual run.
DO $$
DECLARE
  r   RECORD;
  idx INT := 0;
BEGIN
  FOR r IN
    SELECT me.id AS member_id, me.organization_id, me.name
    FROM members me
    JOIN memberships ms ON ms.member_id = me.id
    WHERE ms.status = 'past_due' AND me.id::text LIKE '80000000-0000-0000-0000-0000000000%'
    ORDER BY me.id
  LOOP
    idx := idx + 1;
    INSERT INTO whatsapp_messages (organization_id, member_id, direction, template_name, body_preview, status, created_at)
    VALUES (
      r.organization_id, r.member_id, 'outbound', 'renewal_reminder',
      'Hi ' || r.name || ', your membership renewal is due. Pay here to continue: https://rzp.io/l/seedhist' || idx,
      CASE WHEN idx % 5 = 0 THEN 'failed' ELSE 'sent' END,
      now() - (idx || ' days')::interval
    );
  END LOOP;
END $$;

-- Outbound payment_confirmation for a handful of active new members —
-- one deliberately left 'queued' (stale), same failed-send-detection purpose.
DO $$
DECLARE
  r   RECORD;
  idx INT := 0;
BEGIN
  FOR r IN
    SELECT me.id AS member_id, me.organization_id, me.name
    FROM members me
    JOIN memberships ms ON ms.member_id = me.id
    WHERE ms.status = 'active' AND me.id::text LIKE '80000000-0000-0000-0000-0000000000%'
    ORDER BY me.id
    LIMIT 8
  LOOP
    idx := idx + 1;
    INSERT INTO whatsapp_messages (organization_id, member_id, direction, template_name, body_preview, status, created_at)
    VALUES (
      r.organization_id, r.member_id, 'outbound', 'payment_confirmation',
      'Thanks ' || r.name || '! Your payment was received and your membership is active.',
      CASE WHEN idx = 3 THEN 'queued' ELSE 'delivered' END,
      now() - (idx * 2 || ' days')::interval
    );
  END LOOP;
END $$;

-- Outbound daily_owner_brief broadcast history — every briefable org
-- (active/trial; Bodyline is suspended and correctly gets none), last 5 days.
DO $$
DECLARE
  o RECORD;
  d INT;
BEGIN
  FOR o IN SELECT id, name FROM organizations WHERE status IN ('active', 'trial') LOOP
    FOR d IN 1..5 LOOP
      INSERT INTO whatsapp_messages (organization_id, member_id, direction, template_name, body_preview, status, created_at)
      VALUES (
        o.id, NULL, 'outbound', 'daily_owner_brief',
        'Good morning! ' || o.name || ' — daily summary',
        'sent',
        now() - (d || ' days')::interval
      );
    END LOOP;
  END LOOP;
END $$;

-- A few realistic inbound messages (check-in, PAY, switch).
INSERT INTO whatsapp_messages (organization_id, member_id, direction, body_preview, status, created_at) VALUES
  ('33333333-3333-3333-3333-333333333333', '80000000-0000-0000-0000-000000000011', 'inbound', 'in',   'delivered', now() - interval '3 hours'),
  ('33333333-3333-3333-3333-333333333333', '80000000-0000-0000-0000-000000000013', 'inbound', 'PAY',  'delivered', now() - interval '1 day'),
  ('44444444-4444-4444-4444-444444444444', '80000000-0000-0000-0000-000000000017', 'inbound', 'in',   'delivered', now() - interval '6 hours'),
  ('22222222-2222-2222-2222-222222222222', '80000000-0000-0000-0000-000000000007', 'inbound', 'switch', 'delivered', now() - interval '2 days');

-- ---------------------------------------------------------------------------
-- PT COACHING — coaches, packages, notes, measurements
-- (20260829090000..20260829092000 migrations)
--
-- Purely additive: new id prefixes (c0ac.../9c00.../not reused elsewhere),
-- new phone range 9184540000NN, all PIN 1234 (reuses Ravi's bcrypt hash so no
-- new hash needs computing). Consumed by supabase/rls-test.sh's coaching
-- section; also lets the real coach UI show live data.
--
--   Coaches:  918454000001 Farah Sheikh  coach  Iron Temple / Indiranagar  1234
--             918454000002 Girish Menon   coach  Iron Temple / Indiranagar  1234
--             918454000003 Hema Pillai    coach  FlexFit / Koramangala      1234
--
--   Packages: Farah  -> Asha Menon (e1111111)   active   muscle_gain 12/8
--             Farah  -> Deepak Kumar (8000..01) active   fat_loss    12/3
--             Girish -> Sneha Gupta (8000..02)  active   general     8/2
--             Farah  -> Chitra Iyer (e3333333)  COMPLETED fat_loss   16/16
--             Hema   -> Chitra Iyer FF (e4444444) active muscle_gain 12/5
--   Bharat Rao (e2222222) deliberately has NO package — the "member with no
--   coaching data" fixture.
-- ---------------------------------------------------------------------------
INSERT INTO users (id, organization_id, name, phone, role, location_id, pin_hash) VALUES
  ('c0ac0000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111',
   'Farah Sheikh', '918454000001', 'coach', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
   '$2a$12$on0RNeDins4a4rqt4Mcpse8sQ/em3Irl1orEyXYomtKV7sH64bpNS'), -- pin 1234
  ('c0ac0000-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111',
   'Girish Menon', '918454000002', 'coach', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
   '$2a$12$on0RNeDins4a4rqt4Mcpse8sQ/em3Irl1orEyXYomtKV7sH64bpNS'), -- pin 1234
  ('c0ac0000-0000-0000-0000-000000000003', '22222222-2222-2222-2222-222222222222',
   'Hema Pillai',  '918454000003', 'coach', 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
   '$2a$12$on0RNeDins4a4rqt4Mcpse8sQ/em3Irl1orEyXYomtKV7sH64bpNS'); -- pin 1234

-- duration_months x sessions_per_month = sessions_purchased (all kept
-- explicit and consistent; see 20260829098500_pt_packages_session_calc.sql).
INSERT INTO pt_packages (id, organization_id, member_id, coach_id, goal,
                         duration_months, sessions_per_month,
                         sessions_purchased, sessions_used, price, status, start_date) VALUES
  ('9c000000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111',
   'e1111111-1111-1111-1111-111111111111', 'c0ac0000-0000-0000-0000-000000000001',
   'muscle_gain', 3, 4, 12, 8, 12000.00, 'active', CURRENT_DATE - 60),
  ('9c000000-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111',
   '80000000-0000-0000-0000-000000000001', 'c0ac0000-0000-0000-0000-000000000001',
   'fat_loss', 3, 4, 12, 3, 12000.00, 'active', CURRENT_DATE - 20),
  ('9c000000-0000-0000-0000-000000000003', '11111111-1111-1111-1111-111111111111',
   '80000000-0000-0000-0000-000000000002', 'c0ac0000-0000-0000-0000-000000000002',
   'general_fitness', 2, 4, 8, 2, 8000.00, 'active', CURRENT_DATE - 14),
  ('9c000000-0000-0000-0000-000000000004', '11111111-1111-1111-1111-111111111111',
   'e3333333-3333-3333-3333-333333333333', 'c0ac0000-0000-0000-0000-000000000001',
   'fat_loss', 4, 4, 16, 16, 16000.00, 'completed', CURRENT_DATE - 180),
  ('9c000000-0000-0000-0000-000000000005', '22222222-2222-2222-2222-222222222222',
   'e4444444-4444-4444-4444-444444444444', 'c0ac0000-0000-0000-0000-000000000003',
   'muscle_gain', 3, 4, 12, 5, 15000.00, 'active', CURRENT_DATE - 30);

INSERT INTO training_notes (organization_id, member_id, coach_id, pt_package_id, note_text, session_date) VALUES
  ('11111111-1111-1111-1111-111111111111', 'e1111111-1111-1111-1111-111111111111',
   'c0ac0000-0000-0000-0000-000000000001', '9c000000-0000-0000-0000-000000000001',
   'Increased squat to 80kg, form solid throughout.', CURRENT_DATE - 2),
  ('11111111-1111-1111-1111-111111111111', 'e1111111-1111-1111-1111-111111111111',
   'c0ac0000-0000-0000-0000-000000000001', '9c000000-0000-0000-0000-000000000001',
   'Bench stalled; deloaded to 60kg and rebuilt.', CURRENT_DATE - 9),
  ('11111111-1111-1111-1111-111111111111', '80000000-0000-0000-0000-000000000002',
   'c0ac0000-0000-0000-0000-000000000002', '9c000000-0000-0000-0000-000000000003',
   'Mobility work — hip flexors loosening up.', CURRENT_DATE - 3);

INSERT INTO body_measurements (organization_id, member_id, recorded_by, weight_kg, height_cm, recorded_at) VALUES
  ('11111111-1111-1111-1111-111111111111', 'e1111111-1111-1111-1111-111111111111',
   'c0ac0000-0000-0000-0000-000000000001', 68.0, 176.0, now() - interval '60 days'),
  ('11111111-1111-1111-1111-111111111111', 'e1111111-1111-1111-1111-111111111111',
   'c0ac0000-0000-0000-0000-000000000001', 70.5, 176.0, now() - interval '30 days'),
  ('11111111-1111-1111-1111-111111111111', 'e1111111-1111-1111-1111-111111111111',
   'c0ac0000-0000-0000-0000-000000000001', 72.0, 176.0, now() - interval '2 days'),
  ('11111111-1111-1111-1111-111111111111', '80000000-0000-0000-0000-000000000002',
   'c0ac0000-0000-0000-0000-000000000002', 71.0, 172.0, now() - interval '3 days');

COMMIT;
