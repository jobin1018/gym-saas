-- LOGIN ATTEMPTS — rate-limit / lockout ledger for staff-login.
--
-- Deliberately NO user_id / FK to users. Keyed only on the raw
-- (organization_id, phone) pair the caller presented. A phone that does not
-- correspond to any real user must be rate-limited IDENTICALLY to one that
-- does — otherwise the rate-limit behaviour itself becomes an oracle for
-- which phone numbers are valid staff accounts in a given org, defeating the
-- whole point of staff-login's "invalid_credentials means either" response.
--
-- NO RLS. Same treatment as webhook_events (see the core schema migration):
-- this is security infrastructure, not tenant data — it must never be
-- readable or writable by anon/authenticated under any policy, permissive
-- dev ones included. It stays reachable only via the two SECURITY INVOKER
-- functions in the companion grants migration
-- (20260824130500_grant_service_role_staff_login.sql), which are themselves
-- revoked from anon/authenticated and granted only to service_role.
CREATE TABLE login_attempts (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id   UUID NOT NULL REFERENCES organizations(id),
  phone             TEXT NOT NULL,
  attempted_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  success           BOOLEAN NOT NULL
);

-- Every read staff_login_lockout_status() does is "most recent success" and
-- "failures after some cutoff", both filtered on (organization_id, phone) and
-- ordered by attempted_at — this index covers both in one pass.
CREATE INDEX idx_login_attempts_lookup
  ON login_attempts (organization_id, phone, attempted_at DESC);
