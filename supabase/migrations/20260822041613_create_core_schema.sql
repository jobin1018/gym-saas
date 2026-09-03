-- ORGANIZATIONS / LOCATIONS
CREATE TABLE organizations (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name              TEXT NOT NULL,
  owner_phone       TEXT NOT NULL,
  gst_number        TEXT,
  status            TEXT NOT NULL DEFAULT 'trial'
                      CHECK (status IN ('trial','active','suspended')),
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE locations (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id   UUID NOT NULL REFERENCES organizations(id),
  name              TEXT NOT NULL,
  timezone          TEXT NOT NULL DEFAULT 'Asia/Kolkata',
  address           TEXT,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- USERS (staff/owner logins)
CREATE TABLE users (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id   UUID NOT NULL REFERENCES organizations(id),
  auth_user_id      UUID REFERENCES auth.users(id),
  name              TEXT NOT NULL,
  phone             TEXT NOT NULL,
  role              TEXT NOT NULL CHECK (role IN ('owner','front_desk')),
  location_id       UUID REFERENCES locations(id),
  pin_hash          TEXT,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (organization_id, phone)
);

-- MEMBERS
CREATE TABLE members (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id   UUID NOT NULL REFERENCES organizations(id),
  location_id       UUID NOT NULL REFERENCES locations(id),
  name              TEXT NOT NULL,
  phone             TEXT NOT NULL,
  whatsapp_opt_in   BOOLEAN NOT NULL DEFAULT false,
  source            TEXT DEFAULT 'manual',
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (organization_id, phone)
);

CREATE TABLE member_active_context (
  phone             TEXT PRIMARY KEY,
  active_member_id  UUID NOT NULL REFERENCES members(id),
  active_org_id     UUID NOT NULL REFERENCES organizations(id),
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- MEMBERSHIPS / PLANS
CREATE TABLE membership_plans (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id   UUID NOT NULL REFERENCES organizations(id),
  name              TEXT NOT NULL,
  amount            NUMERIC(10,2) NOT NULL,
  billing_interval  TEXT NOT NULL DEFAULT 'monthly' CHECK (billing_interval = 'monthly'),
  active            BOOLEAN NOT NULL DEFAULT true
);

CREATE TABLE memberships (
  id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id       UUID NOT NULL REFERENCES organizations(id),
  member_id             UUID NOT NULL REFERENCES members(id),
  plan_id               UUID NOT NULL REFERENCES membership_plans(id),
  status                TEXT NOT NULL DEFAULT 'active'
                          CHECK (status IN ('active','past_due','expired','cancelled')),
  start_date            DATE NOT NULL,
  current_period_end    DATE NOT NULL,
  created_at            TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- PAYMENTS
CREATE TABLE payments (
  id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id       UUID NOT NULL REFERENCES organizations(id),
  membership_id         UUID NOT NULL REFERENCES memberships(id),
  amount                NUMERIC(10,2) NOT NULL,
  provider              TEXT NOT NULL DEFAULT 'razorpay',
  provider_payment_id   TEXT UNIQUE,
  razorpay_link_id      TEXT,
  status                TEXT NOT NULL DEFAULT 'pending'
                          CHECK (status IN ('pending','success','failed','manual')),
  idempotency_key       TEXT NOT NULL UNIQUE,
  created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
  reconciled_at         TIMESTAMPTZ
);

-- ATTENDANCE
CREATE TABLE attendance (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id   UUID NOT NULL REFERENCES organizations(id),
  member_id         UUID NOT NULL REFERENCES members(id),
  checked_in_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  source            TEXT NOT NULL DEFAULT 'whatsapp_self'
                      CHECK (source IN ('whatsapp_self','front_desk','biometric')),
  marked_by         UUID REFERENCES users(id)
);

-- WHATSAPP MESSAGE LOG
CREATE TABLE whatsapp_messages (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id   UUID REFERENCES organizations(id),
  member_id         UUID REFERENCES members(id),
  direction         TEXT NOT NULL CHECK (direction IN ('inbound','outbound')),
  template_name     TEXT,
  body_preview      TEXT,
  wa_message_id     TEXT,
  status            TEXT NOT NULL DEFAULT 'queued'
                      CHECK (status IN ('queued','sent','delivered','read','failed')),
  related_payment_id UUID REFERENCES payments(id),
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- WEBHOOK EVENTS (idempotency + audit log)
CREATE TABLE webhook_events (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  source            TEXT NOT NULL CHECK (source IN ('razorpay','meta')),
  event_id          TEXT NOT NULL,
  payload           JSONB NOT NULL,
  processed         BOOLEAN NOT NULL DEFAULT false,
  received_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (source, event_id)
);

-- INDEXES
CREATE INDEX idx_memberships_due   ON memberships (organization_id, status, current_period_end);
CREATE INDEX idx_payments_status   ON payments (organization_id, status, created_at);
CREATE INDEX idx_attendance_member ON attendance (organization_id, member_id, checked_in_at);
CREATE INDEX idx_wa_msgs_member    ON whatsapp_messages (organization_id, member_id, created_at);

-- ANALYTICS VIEWS
CREATE VIEW v_daily_revenue AS
SELECT organization_id, date_trunc('day', reconciled_at) AS day,
       SUM(amount) AS total, COUNT(*) AS payment_count
FROM payments WHERE status = 'success'
GROUP BY organization_id, day;

CREATE VIEW v_lapsed_members AS
SELECT m.id, m.organization_id, m.name, MAX(a.checked_in_at) AS last_visit
FROM members m LEFT JOIN attendance a ON a.member_id = m.id
GROUP BY m.id
HAVING MAX(a.checked_in_at) < now() - INTERVAL '14 days' OR MAX(a.checked_in_at) IS NULL;

-- ROW-LEVEL SECURITY
ALTER TABLE organizations ENABLE ROW LEVEL SECURITY;
ALTER TABLE locations ENABLE ROW LEVEL SECURITY;
ALTER TABLE users ENABLE ROW LEVEL SECURITY;
ALTER TABLE members ENABLE ROW LEVEL SECURITY;
ALTER TABLE membership_plans ENABLE ROW LEVEL SECURITY;
ALTER TABLE memberships ENABLE ROW LEVEL SECURITY;
ALTER TABLE payments ENABLE ROW LEVEL SECURITY;
ALTER TABLE attendance ENABLE ROW LEVEL SECURITY;
ALTER TABLE whatsapp_messages ENABLE ROW LEVEL SECURITY;

CREATE POLICY tenant_isolation_orgs ON organizations
  USING (id = current_setting('app.current_org_id')::uuid);
CREATE POLICY tenant_isolation_locations ON locations
  USING (organization_id = current_setting('app.current_org_id')::uuid);
CREATE POLICY tenant_isolation_users ON users
  USING (organization_id = current_setting('app.current_org_id')::uuid);
CREATE POLICY tenant_isolation_members ON members
  USING (organization_id = current_setting('app.current_org_id')::uuid);
CREATE POLICY tenant_isolation_plans ON membership_plans
  USING (organization_id = current_setting('app.current_org_id')::uuid);
CREATE POLICY tenant_isolation_memberships ON memberships
  USING (organization_id = current_setting('app.current_org_id')::uuid);
CREATE POLICY tenant_isolation_payments ON payments
  USING (organization_id = current_setting('app.current_org_id')::uuid);
CREATE POLICY tenant_isolation_attendance ON attendance
  USING (organization_id = current_setting('app.current_org_id')::uuid);
CREATE POLICY tenant_isolation_wa_messages ON whatsapp_messages
  USING (organization_id = current_setting('app.current_org_id')::uuid);