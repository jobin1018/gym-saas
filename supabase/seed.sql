-- Local dev seed. Applied automatically by `supabase db reset`
-- (see [db.seed] sql_paths in config.toml). Safe to delete.
--
-- Test phone numbers for the whatsapp-webhook function:
--   919999999999  → Iron Temple only, ACTIVE membership   → "Checked in ✅"
--   918888888888  → Iron Temple only, PAST_DUE membership → renewal reply, no attendance
--   917777777777  → member at BOTH gyms, no active context → disambiguation prompt
--   916666666666  → not a member anywhere                 → "We couldn't find you"
--
-- Staff/owner logins (public.users) — one owner + one front desk per gym.
-- PINs below are LOCAL DEV ONLY, chosen to be easy to type and remember —
-- never do this for a real deployment. Verify with staff-login (bcrypt
-- compare against pin_hash, see that function's own docs for why bcrypt was
-- chosen over argon2 for a 4-digit keyspace):
--   919000000001 Ravi Krishnan  owner       Iron Temple  pin 1234  (= organizations.owner_phone)
--   919000000011 Priya Nair     front_desk  Iron Temple  pin 1111
--   919000000002 Sanjay Mehta   owner       FlexFit      pin 2345  (= organizations.owner_phone)
--   919000000012 Divya Shetty   front_desk  FlexFit      pin 2222
--
-- Payment fixtures for the razorpay-webhook function:
--   pay_TEST_CAPTURED  → pending payment on Asha's ACTIVE membership   (capture path)
--   pay_TEST_FAILED    → pending payment on Bharat's PAST_DUE membership (failure path)
--   plink_TEST_LINK    → pending payment with NO provider_payment_id yet,
--                        matched by razorpay_link_id (payment_link.paid path)

BEGIN;

INSERT INTO organizations (id, name, owner_phone, status) VALUES
  ('11111111-1111-1111-1111-111111111111', 'Iron Temple Gym', '919000000001', 'active'),
  ('22222222-2222-2222-2222-222222222222', 'FlexFit Studio',  '919000000002', 'active');

INSERT INTO locations (id, organization_id, name) VALUES
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', '11111111-1111-1111-1111-111111111111', 'Iron Temple — Indiranagar'),
  ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', '22222222-2222-2222-2222-222222222222', 'FlexFit — Koramangala');

-- STAFF / OWNER LOGINS
--
-- pin_hash is a real bcrypt hash (cost 12) of the PIN listed in the header
-- comment above, computed once with the same npm:bcryptjs library
-- staff-login/index.ts uses at request time — these are not placeholders.
-- auth_user_id stays NULL: it is the bridge to Supabase Auth, and staff-login
-- populates it lazily on a user's first successful login rather than here.
--
-- OWNER PHONES INTENTIONALLY MATCH organizations.owner_phone. Nothing in the
-- schema enforces that — there is no FK and no constraint tying the two
-- together — so it is possible to have an owner logging in on one number while
-- daily-owner-brief messages a different one. Keeping them equal here makes the
-- intended relationship visible in the data; deciding which of the two is
-- authoritative is still an open question.
--
-- location_id is NULL for owners (they are not tied to a branch) and set for
-- front-desk staff (they work one). attendance.marked_by references these rows.
INSERT INTO users (id, organization_id, name, phone, role, location_id, pin_hash) VALUES
  -- Iron Temple Gym
  ('91111111-1111-1111-1111-111111111111', '11111111-1111-1111-1111-111111111111',
   'Ravi Krishnan', '919000000001', 'owner',      NULL,
   '$2a$12$on0RNeDins4a4rqt4Mcpse8sQ/em3Irl1orEyXYomtKV7sH64bpNS'), -- pin 1234
  ('92222222-2222-2222-2222-222222222222', '11111111-1111-1111-1111-111111111111',
   'Priya Nair',    '919000000011', 'front_desk',
   'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
   '$2a$12$z4yhVi.IJU8huu5x/9.tl.bOEfYHoc4nacMxkYZkc4omzCPP9gd7K'), -- pin 1111
  -- FlexFit Studio
  ('93333333-3333-3333-3333-333333333333', '22222222-2222-2222-2222-222222222222',
   'Sanjay Mehta',  '919000000002', 'owner',      NULL,
   '$2a$12$bbAzBvScb.2lMUqcMsPNJOgYLb6BaY1bW0fn9tjjlXkKE1etAQvlK'), -- pin 2345
  ('94444444-4444-4444-4444-444444444444', '22222222-2222-2222-2222-222222222222',
   'Divya Shetty',  '919000000012', 'front_desk',
   'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
   '$2a$12$P2guAJ41at5K/RCytsI8zevhRcAEX/3S0n0xfbWPqGBqY6zU21HOi'); -- pin 2222

INSERT INTO membership_plans (id, organization_id, name, amount) VALUES
  ('cccccccc-cccc-cccc-cccc-cccccccccccc', '11111111-1111-1111-1111-111111111111', 'Monthly Unlimited', 1500.00),
  ('dddddddd-dddd-dddd-dddd-dddddddddddd', '22222222-2222-2222-2222-222222222222', 'Monthly Studio',    2000.00);

INSERT INTO members (id, organization_id, location_id, name, phone, whatsapp_opt_in, source) VALUES
  -- single gym, active
  ('e1111111-1111-1111-1111-111111111111', '11111111-1111-1111-1111-111111111111',
   'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'Asha Menon',   '919999999999', true, 'manual'),
  -- single gym, past due
  ('e2222222-2222-2222-2222-222222222222', '11111111-1111-1111-1111-111111111111',
   'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'Bharat Rao',   '918888888888', true, 'manual'),
  -- same phone at two orgs (allowed: UNIQUE is on (organization_id, phone))
  ('e3333333-3333-3333-3333-333333333333', '11111111-1111-1111-1111-111111111111',
   'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'Chitra Iyer',  '917777777777', true, 'manual'),
  ('e4444444-4444-4444-4444-444444444444', '22222222-2222-2222-2222-222222222222',
   'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'Chitra Iyer',  '917777777777', true, 'manual');

-- Explicit membership ids so payments fixtures can reference them.
INSERT INTO memberships (id, organization_id, member_id, plan_id, status, start_date, current_period_end) VALUES
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
   'active',   CURRENT_DATE - 5,  CURRENT_DATE + 25);

-- Pending payments, as send-renewal-reminder would have created them.
INSERT INTO payments (id, organization_id, membership_id, amount, provider,
                      provider_payment_id, razorpay_link_id, status, idempotency_key) VALUES
  ('a1111111-1111-1111-1111-111111111111', '11111111-1111-1111-1111-111111111111',
   'f1111111-1111-1111-1111-111111111111', 1500.00, 'razorpay',
   'pay_TEST_CAPTURED', NULL,              'pending', 'seed-idem-captured'),
  ('a2222222-2222-2222-2222-222222222222', '11111111-1111-1111-1111-111111111111',
   'f2222222-2222-2222-2222-222222222222', 1500.00, 'razorpay',
   'pay_TEST_FAILED',   NULL,              'pending', 'seed-idem-failed'),
  -- Link created but not yet paid: provider_payment_id is still NULL, so this
  -- row can only be found via razorpay_link_id.
  ('a3333333-3333-3333-3333-333333333333', '11111111-1111-1111-1111-111111111111',
   'f3333333-3333-3333-3333-333333333333', 1500.00, 'razorpay',
   NULL,                'plink_TEST_LINK', 'pending', 'seed-idem-link');

COMMIT;
