-- Coaching / personal-training tables: pt_packages, training_notes,
-- body_measurements.
--
-- ============================================================================
-- THE MODEL (decided before this migration, encoded here)
-- ============================================================================
-- pt_packages is the COMMERCIAL setup: owner/front_desk create it the same way
-- they attach a membership plan — session count, price, goal, assigned coach.
-- The coach DELIVERS against it (training_notes, body_measurements) but never
-- creates or edits the package. RLS in 20260829091500 enforces that split;
-- this migration is just the shapes + integrity.
--
-- ============================================================================
-- PAYMENT LINKING — DEFERRED, ON PURPOSE
-- ============================================================================
-- A PT package costs money, so the "obviously symmetrical" move is to link it
-- to `payments` the way membership billing does. We are NOT doing that in this
-- pass, as a deliberate scope decision:
--
--   * payments.membership_id is NOT NULL and the whole Razorpay path
--     (send-renewal-reminder -> razorpay-webhook -> mark-overdue -> renewal
--     -scan) is membership-shaped end to end. Linking PT packages means making
--     payments.membership_id nullable, adding pt_packages_id, a
--     one-of-two-must-be-set CHECK, an idempotency-key scheme for PT, and
--     teaching the webhook reconciliation + the three cron functions about a
--     second billable entity. That is a money-path change touching six files
--     and four existing migrations.
--   * The validated UI treats `price` as a recorded figure on the package
--     (what front desk agreed with the member), not a checkout. Nothing in
--     the mock initiates a PT payment.
--
-- So `pt_packages.price` is the agreed amount, recorded, no payment row.
-- When PT billing is built it should add a NULLABLE pt_packages.payment_id
-- (-> payments.id) plus the payments.membership_id nullability change above —
-- a small follow-up migration, not a reshaping of this table.
--
-- ============================================================================
-- BMI — GENERATED STORED COLUMN, not application logic
-- ============================================================================
-- Every body_measurements row carries its own weight_kg AND height_cm (the UI
-- defaults height to the member's last-recorded value but writes a fresh
-- snapshot every time, and allows correcting it). BMI is therefore a pure
-- function of two columns in the SAME row — the textbook case for a generated
-- column. Benefits over computing in the client / an Edge Function:
--   * impossible to persist an inconsistent BMI;
--   * one formula, in the database, instead of the frontend's computeBmi()
--     being re-implemented by every future reader (owner reports, analytics);
--   * rounding matches the frontend (1 decimal) so the chart doesn't jump
--     when it switches from local compute to the stored value.
-- CHECK (height_cm > 0) guards the division — a zero would make the generated
-- expression raise on insert rather than store garbage.
--
-- "What was this member's most recent height/weight" is
--   SELECT height_cm, weight_kg, bmi FROM body_measurements
--    WHERE organization_id = $1 AND member_id = $2
--    ORDER BY recorded_at DESC LIMIT 1
-- served entirely by idx_body_measurements_member_recent below.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- pt_packages
-- ---------------------------------------------------------------------------
CREATE TABLE public.pt_packages (
  id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id     UUID NOT NULL REFERENCES public.organizations(id),
  member_id           UUID NOT NULL REFERENCES public.members(id),
  coach_id            UUID NOT NULL REFERENCES public.users(id),
  -- Values match the frontend's Goal union (mockCoachData.ts).
  goal                TEXT NOT NULL
                        CHECK (goal IN ('muscle_gain', 'fat_loss', 'general_fitness')),
  sessions_purchased  INTEGER NOT NULL CHECK (sessions_purchased > 0),
  sessions_used       INTEGER NOT NULL DEFAULT 0 CHECK (sessions_used >= 0),
  price               NUMERIC(10,2) NOT NULL CHECK (price >= 0),
  status              TEXT NOT NULL DEFAULT 'active'
                        CHECK (status IN ('active', 'completed', 'cancelled')),
  start_date          DATE NOT NULL DEFAULT CURRENT_DATE,
  created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT pt_packages_used_lte_purchased CHECK (sessions_used <= sessions_purchased)
);

-- Covers both the coach path (WHERE org + coach_id + status='active') and the
-- front_desk/owner path (WHERE org + member_id) used by the RLS policies and
-- the "packages for this member" client-detail query.
CREATE INDEX idx_pt_packages_coach  ON public.pt_packages (organization_id, coach_id, status);
CREATE INDEX idx_pt_packages_member ON public.pt_packages (organization_id, member_id, status);

-- ---------------------------------------------------------------------------
-- coach_id must be a role='coach' user in the SAME org; member_id must be in
-- the same org. A CHECK can't do cross-row lookups, and RLS WITH CHECK only
-- guards the PostgREST path (service_role, seed.sql and psql bypass it). This
-- trigger closes that gap for every writer.
--
-- SECURITY DEFINER + pinned search_path: it reads public.users, which
-- `authenticated` has NO grant on (pin_hash) — so as a plain SECURITY INVOKER
-- trigger it would raise "permission denied for table users" the moment a
-- front_desk session inserted a package. Same discipline as
-- custom_access_token_hook() and trigger_renewal_scan().
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.pt_packages_validate_refs()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_coach_role TEXT;
  v_coach_org  UUID;
  v_member_org UUID;
BEGIN
  SELECT role, organization_id INTO v_coach_role, v_coach_org
    FROM public.users WHERE id = NEW.coach_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'pt_packages.coach_id % does not exist in users', NEW.coach_id;
  END IF;
  IF v_coach_role <> 'coach' THEN
    RAISE EXCEPTION 'pt_packages.coach_id % has role %, must be coach', NEW.coach_id, v_coach_role;
  END IF;
  IF v_coach_org <> NEW.organization_id THEN
    RAISE EXCEPTION 'pt_packages.coach_id % belongs to org %, not %',
      NEW.coach_id, v_coach_org, NEW.organization_id;
  END IF;

  SELECT organization_id INTO v_member_org
    FROM public.members WHERE id = NEW.member_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'pt_packages.member_id % does not exist in members', NEW.member_id;
  END IF;
  IF v_member_org <> NEW.organization_id THEN
    RAISE EXCEPTION 'pt_packages.member_id % belongs to org %, not %',
      NEW.member_id, v_member_org, NEW.organization_id;
  END IF;

  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.pt_packages_validate_refs() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.pt_packages_validate_refs() FROM anon, authenticated, service_role;

CREATE TRIGGER trg_pt_packages_validate_refs
  BEFORE INSERT OR UPDATE OF coach_id, member_id, organization_id ON public.pt_packages
  FOR EACH ROW EXECUTE FUNCTION public.pt_packages_validate_refs();

-- ---------------------------------------------------------------------------
-- training_notes — one row per logged session observation.
-- pt_package_id is NOT NULL: a note only exists in the context of a package
-- (it's how the coach path in RLS ties note -> package -> assignment).
-- Append-only by design — no UPDATE/DELETE grant in the companion migration.
-- ---------------------------------------------------------------------------
CREATE TABLE public.training_notes (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id  UUID NOT NULL REFERENCES public.organizations(id),
  member_id        UUID NOT NULL REFERENCES public.members(id),
  coach_id         UUID NOT NULL REFERENCES public.users(id),
  pt_package_id    UUID NOT NULL REFERENCES public.pt_packages(id),
  note_text        TEXT NOT NULL CHECK (length(btrim(note_text)) > 0),
  session_date     DATE NOT NULL DEFAULT CURRENT_DATE,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_training_notes_member  ON public.training_notes (organization_id, member_id, session_date DESC);
CREATE INDEX idx_training_notes_package ON public.training_notes (pt_package_id, session_date DESC);

-- ---------------------------------------------------------------------------
-- body_measurements — one row per weigh-in. No pt_package_id: a member's
-- measurement history is continuous and outlives any single package. The
-- coach path in RLS reaches it via member_id + an active assignment instead.
-- recorded_by is the coach (or owner) who entered it. Append-only.
-- ---------------------------------------------------------------------------
CREATE TABLE public.body_measurements (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id  UUID NOT NULL REFERENCES public.organizations(id),
  member_id        UUID NOT NULL REFERENCES public.members(id),
  recorded_by      UUID NOT NULL REFERENCES public.users(id),
  -- Bounds are deliberately wider than the frontend's own 30-300 kg / 100-250
  -- cm validation but tight enough that the generated bmi below can never
  -- overflow numeric(6,2): the smallest allowed height (50 cm) with the
  -- largest allowed weight (500 kg) is BMI 2000, well under 9999.99. A bare
  -- `height_cm > 0` would let height_cm = 0.5 through the CHECK and then blow
  -- up the division on insert.
  weight_kg        NUMERIC(5,2) NOT NULL CHECK (weight_kg BETWEEN 20 AND 500),
  height_cm        NUMERIC(5,2) NOT NULL CHECK (height_cm BETWEEN 50 AND 300),
  bmi              NUMERIC(6,2) GENERATED ALWAYS AS
                     (round((weight_kg / power(height_cm / 100.0, 2))::numeric, 1)) STORED,
  recorded_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_body_measurements_member_recent
  ON public.body_measurements (organization_id, member_id, recorded_at DESC);

COMMENT ON COLUMN public.body_measurements.bmi IS
  'Generated: round(weight_kg / (height_cm/100)^2, 1). Matches the frontend '
  'computeBmi() so the client can stop computing it locally.';
