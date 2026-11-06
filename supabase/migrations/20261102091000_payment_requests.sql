-- UPI QR payment requests, the pay-page rate limiter, and "skipped" records.
--
-- payment_requests: one row = one pay-page link given to a member. It never
-- represents money. A member "claiming" they paid only stamps claimed_paid_at;
-- staff then confirm via record_manual_payment(..., 'upi'), which is the only
-- thing that extends a membership or creates a payment.
--
-- NO direct table access for anon/authenticated: RLS on, no policies, grants
-- revoked. Everything goes through the SECURITY DEFINER functions below, and
-- the ones the Edge Functions call are service_role-only.

CREATE TABLE public.payment_requests (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id  UUID NOT NULL REFERENCES public.organizations(id),
  membership_id    UUID REFERENCES public.memberships(id),
  pt_package_id    UUID REFERENCES public.pt_packages(id),
  -- The membership period this request pays for (current_period_end when it
  -- was created). NULL for PT packages, which have no period.
  period_end       DATE,
  -- 128 bits of randomness, 32 hex chars.
  token            TEXT NOT NULL UNIQUE
                     DEFAULT encode(extensions.gen_random_bytes(16), 'hex'),
  amount           NUMERIC(10,2) NOT NULL CHECK (amount > 0),
  expires_at       TIMESTAMPTZ NOT NULL,
  claimed_paid_at  TIMESTAMPTZ,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT payment_requests_one_subject
    CHECK ((membership_id IS NULL) <> (pt_package_id IS NULL)),
  CONSTRAINT payment_requests_membership_has_period
    CHECK (membership_id IS NULL OR period_end IS NOT NULL),
  CONSTRAINT payment_requests_token_shape CHECK (token ~ '^[0-9a-f]{32}$')
);

-- One request per membership period / per PT package: reuse, never duplicate.
CREATE UNIQUE INDEX uq_payment_requests_membership_period
  ON public.payment_requests (membership_id, period_end) WHERE membership_id IS NOT NULL;
CREATE UNIQUE INDEX uq_payment_requests_pt_package
  ON public.payment_requests (pt_package_id) WHERE pt_package_id IS NOT NULL;
CREATE INDEX idx_payment_requests_claims
  ON public.payment_requests (organization_id, claimed_paid_at) WHERE claimed_paid_at IS NOT NULL;

ALTER TABLE public.payment_requests ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.payment_requests FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.payment_requests TO service_role;

-- ---------------------------------------------------------------------------
-- Rate limiter for the two public functions. Keyed on a hash the caller
-- computes (never a raw IP). No RLS, no grants: service_role via the function.
-- ---------------------------------------------------------------------------
CREATE TABLE public.pay_page_hits (
  id      BIGSERIAL PRIMARY KEY,
  bucket  TEXT NOT NULL,
  hit_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_pay_page_hits_bucket ON public.pay_page_hits (bucket, hit_at DESC);
ALTER TABLE public.pay_page_hits ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.pay_page_hits FROM PUBLIC, anon, authenticated;

CREATE FUNCTION public.pay_page_rate_check(p_bucket text, p_limit integer, p_window_seconds integer)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_n integer;
BEGIN
  -- Housekeeping: drop anything older than an hour, cheaply, on ~1% of calls.
  IF random() < 0.01 THEN
    DELETE FROM public.pay_page_hits WHERE hit_at < now() - interval '1 hour';
  END IF;
  SELECT count(*) INTO v_n FROM public.pay_page_hits
   WHERE bucket = p_bucket AND hit_at > now() - make_interval(secs => p_window_seconds);
  IF v_n >= p_limit THEN
    RETURN false;
  END IF;
  INSERT INTO public.pay_page_hits (bucket) VALUES (p_bucket);
  RETURN true;
END $$;
REVOKE ALL ON FUNCTION public.pay_page_rate_check(text, integer, integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.pay_page_rate_check(text, integer, integer) TO service_role;

-- ---------------------------------------------------------------------------
-- Skip records: send-renewal-reminder found no usable way for the member to
-- pay, so it sent nothing and wrote down why. Read by the owner via
-- v_payment_setup_alerts and by the owner's ALERTS command.
-- ---------------------------------------------------------------------------
CREATE TABLE public.payment_link_skips (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id  UUID NOT NULL REFERENCES public.organizations(id),
  membership_id    UUID REFERENCES public.memberships(id),
  reason           TEXT NOT NULL,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_payment_link_skips_org ON public.payment_link_skips (organization_id, created_at DESC);
ALTER TABLE public.payment_link_skips ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.payment_link_skips FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT ON public.payment_link_skips TO service_role;

CREATE VIEW public.v_payment_setup_alerts AS
SELECT s.organization_id,
       s.reason,
       count(*)                       AS skipped_count,
       count(DISTINCT s.membership_id) AS member_count,
       max(s.created_at)              AS last_skipped_at
  FROM public.payment_link_skips s
 WHERE s.created_at > now() - interval '7 days'
   AND s.organization_id = (auth.jwt() ->> 'org_id')::uuid
   AND (auth.jwt() ->> 'app_role') = 'owner'
   AND public.current_org_active()
 GROUP BY s.organization_id, s.reason;

COMMENT ON VIEW public.v_payment_setup_alerts IS
  'Owner-only (DEFINER view, self-scoped from the JWT): renewal reminders that '
  'were NOT sent in the last 7 days because the gym has no usable payment '
  'method, grouped by reason.';
REVOKE ALL ON public.v_payment_setup_alerts FROM PUBLIC, anon;
GRANT SELECT ON public.v_payment_setup_alerts TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- get_or_create_payment_request — idempotent per membership period / PT package.
-- Reuses a live row; an EXPIRED row is re-armed with a NEW token and expiry, so
-- an old leaked link never comes back to life. Never creates a second row.
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.get_or_create_payment_request(
  p_membership_id uuid,
  p_pt_package_id uuid,
  p_amount        numeric,
  p_ttl_days      integer DEFAULT 30
)
RETURNS TABLE(request_id uuid, token text, expires_at timestamptz, reused boolean, claimed_paid_at timestamptz)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_org    uuid;
  v_period date;
  r        public.payment_requests%ROWTYPE;
BEGIN
  IF (p_membership_id IS NULL) = (p_pt_package_id IS NULL) THEN
    RAISE EXCEPTION 'subject_invalid';
  END IF;
  IF p_amount IS NULL OR p_amount <= 0 THEN
    RAISE EXCEPTION 'amount_invalid';
  END IF;

  IF p_membership_id IS NOT NULL THEN
    SELECT ms.organization_id, ms.current_period_end INTO v_org, v_period
      FROM public.memberships ms WHERE ms.id = p_membership_id;
  ELSE
    SELECT pk.organization_id INTO v_org FROM public.pt_packages pk WHERE pk.id = p_pt_package_id;
  END IF;
  IF v_org IS NULL THEN
    RAISE EXCEPTION 'subject_not_found';
  END IF;

  LOOP
    IF p_membership_id IS NOT NULL THEN
      SELECT * INTO r FROM public.payment_requests pr
       WHERE pr.membership_id = p_membership_id AND pr.period_end = v_period FOR UPDATE;
    ELSE
      SELECT * INTO r FROM public.payment_requests pr
       WHERE pr.pt_package_id = p_pt_package_id FOR UPDATE;
    END IF;

    IF FOUND THEN
      IF r.expires_at <= now() THEN
        UPDATE public.payment_requests pr
           SET token = encode(extensions.gen_random_bytes(16), 'hex'),
               expires_at = now() + make_interval(days => p_ttl_days),
               amount = p_amount
         WHERE pr.id = r.id
         RETURNING * INTO r;
      END IF;
      RETURN QUERY SELECT r.id, r.token, r.expires_at, true, r.claimed_paid_at;
      RETURN;
    END IF;

    BEGIN
      INSERT INTO public.payment_requests
        (organization_id, membership_id, pt_package_id, period_end, amount, expires_at)
      VALUES
        (v_org, p_membership_id, p_pt_package_id, v_period, p_amount,
         now() + make_interval(days => p_ttl_days))
      RETURNING * INTO r;
      RETURN QUERY SELECT r.id, r.token, r.expires_at, false, r.claimed_paid_at;
      RETURN;
    EXCEPTION WHEN unique_violation THEN
      NULL; -- concurrent creator won; loop and reuse theirs
    END;
  END LOOP;
END $$;
REVOKE ALL ON FUNCTION public.get_or_create_payment_request(uuid, uuid, numeric, integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_or_create_payment_request(uuid, uuid, numeric, integer) TO service_role;

-- ---------------------------------------------------------------------------
-- get_pay_page_data — everything the pay page may show, for a LIVE token.
-- Returns zero rows for unknown/expired tokens; org_active tells the caller to
-- refuse. Only the member's FIRST name leaves the database.
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.get_pay_page_data(p_token text)
RETURNS TABLE(
  request_id       uuid,
  organization_id  uuid,
  gym_name         text,
  org_active       boolean,
  member_first_name text,
  plan_name        text,
  subject          text,
  amount           numeric,
  expires_at       timestamptz,
  claimed_paid_at  timestamptz,
  upi_id           text,
  qr_image_path    text,
  qr_enabled       boolean,
  razorpay_enabled boolean
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT pr.id, pr.organization_id, o.name, (o.status IN ('trial','active')),
         split_part(btrim(m.name), ' ', 1),
         CASE WHEN pr.membership_id IS NOT NULL THEN mp.name ELSE 'Personal training' END,
         CASE WHEN pr.membership_id IS NOT NULL THEN 'membership' ELSE 'pt_package' END,
         pr.amount, pr.expires_at, pr.claimed_paid_at,
         s.upi_id, s.qr_image_path, COALESCE(s.qr_enabled, false), COALESCE(s.razorpay_enabled, false)
    FROM public.payment_requests pr
    JOIN public.organizations o ON o.id = pr.organization_id
    LEFT JOIN public.memberships ms ON ms.id = pr.membership_id
    LEFT JOIN public.membership_plans mp ON mp.id = ms.plan_id
    LEFT JOIN public.pt_packages pk ON pk.id = pr.pt_package_id
    JOIN public.members m ON m.id = COALESCE(ms.member_id, pk.member_id)
    LEFT JOIN public.org_payment_settings s ON s.organization_id = pr.organization_id
   WHERE pr.token = p_token
     AND pr.expires_at > now();
$$;
REVOKE ALL ON FUNCTION public.get_pay_page_data(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_pay_page_data(text) TO service_role;

-- ---------------------------------------------------------------------------
-- claim_payment_request — the member says "I've paid". Stamps claimed_paid_at
-- ONCE. Touches nothing else: no payment row, no membership change.
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.claim_payment_request(p_token text)
RETURNS TABLE(outcome text, request_id uuid, organization_id uuid, claimed_paid_at timestamptz)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE r public.payment_requests%ROWTYPE; v_active boolean;
BEGIN
  SELECT * INTO r FROM public.payment_requests pr
   WHERE pr.token = p_token AND pr.expires_at > now() FOR UPDATE;
  IF NOT FOUND THEN
    RETURN QUERY SELECT 'not_found'::text, NULL::uuid, NULL::uuid, NULL::timestamptz;
    RETURN;
  END IF;
  SELECT (o.status IN ('trial','active')) INTO v_active FROM public.organizations o WHERE o.id = r.organization_id;
  IF NOT COALESCE(v_active, false) THEN
    RETURN QUERY SELECT 'org_inactive'::text, r.id, r.organization_id, r.claimed_paid_at;
    RETURN;
  END IF;
  IF r.claimed_paid_at IS NOT NULL THEN
    RETURN QUERY SELECT 'already_claimed'::text, r.id, r.organization_id, r.claimed_paid_at;
    RETURN;
  END IF;
  UPDATE public.payment_requests pr SET claimed_paid_at = now() WHERE pr.id = r.id
    RETURNING pr.claimed_paid_at INTO r.claimed_paid_at;
  RETURN QUERY SELECT 'claimed'::text, r.id, r.organization_id, r.claimed_paid_at;
END $$;
REVOKE ALL ON FUNCTION public.claim_payment_request(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.claim_payment_request(text) TO service_role;

-- ---------------------------------------------------------------------------
-- list_pending_payment_claims — staff view of "member says paid, not yet
-- recorded". Owner: whole org. front_desk: own location. A claim is pending
-- until the money is recorded: for a membership, until current_period_end moves
-- past the period the request was for; for a PT package, until a collected
-- payment exists. Confirm with record_manual_payment(..., 'upi').
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.list_pending_payment_claims()
RETURNS TABLE(
  request_id      uuid,
  claimed_paid_at timestamptz,
  amount          numeric,
  subject         text,
  membership_id   uuid,
  pt_package_id   uuid,
  member_id       uuid,
  member_name     text,
  member_phone    text,
  plan_name       text,
  location_id     uuid
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_org  uuid := (auth.jwt() ->> 'org_id')::uuid;
  v_role text := (auth.jwt() ->> 'app_role');
  v_loc  uuid := (auth.jwt() ->> 'location_id')::uuid;
BEGIN
  IF v_org IS NULL OR v_role NOT IN ('owner', 'front_desk') THEN
    RAISE EXCEPTION 'not_authorized' USING errcode = '42501';
  END IF;
  IF NOT public.current_org_active() THEN
    RAISE EXCEPTION 'organization_suspended' USING errcode = 'P0001';
  END IF;

  RETURN QUERY
  SELECT pr.id, pr.claimed_paid_at, pr.amount,
         CASE WHEN pr.membership_id IS NOT NULL THEN 'membership' ELSE 'pt_package' END,
         pr.membership_id, pr.pt_package_id, m.id, m.name, m.phone,
         CASE WHEN pr.membership_id IS NOT NULL THEN mp.name ELSE 'Personal training' END,
         m.location_id
    FROM public.payment_requests pr
    LEFT JOIN public.memberships ms ON ms.id = pr.membership_id
    LEFT JOIN public.membership_plans mp ON mp.id = ms.plan_id
    LEFT JOIN public.pt_packages pk ON pk.id = pr.pt_package_id
    JOIN public.members m ON m.id = COALESCE(ms.member_id, pk.member_id)
   WHERE pr.organization_id = v_org
     AND pr.claimed_paid_at IS NOT NULL
     AND (v_role = 'owner' OR (v_loc IS NOT NULL AND m.location_id = v_loc))
     AND (
       (pr.membership_id IS NOT NULL AND ms.current_period_end <= pr.period_end)
       OR (pr.pt_package_id IS NOT NULL AND NOT EXISTS (
             SELECT 1 FROM public.payments p
              WHERE p.pt_package_id = pr.pt_package_id
                AND public.payment_is_collected(p.status)))
     )
   ORDER BY pr.claimed_paid_at DESC;
END $$;
REVOKE ALL ON FUNCTION public.list_pending_payment_claims() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.list_pending_payment_claims() TO authenticated;
