-- Rewrite every tenant_isolation_* policy from current_setting() to auth.jwt().
--
-- ============================================================================
-- WHY: current_setting('app.current_org_id') never had anything to set it
-- ============================================================================
-- Every policy below predates real auth entirely — they were written against
-- a GUC nothing ever SET, as a placeholder for "this is where tenant scoping
-- goes once there is a JWT to read." 20260824140000_create_custom_access_
-- token_hook.sql is what now puts org_id / app_role / location_id onto every
-- token; this migration is what reads them back out.
--
-- current_setting('app.current_org_id')::uuid) on a genuinely unset GUC does
-- not return NULL — it RAISES a Postgres error (the two-argument form,
-- current_setting(name, missing_ok), would return NULL instead, but that is
-- not what the original policies used). An unauthenticated or claim-less
-- request therefore did not fail closed — it failed LOUD, as a 500, which
-- can leak information about server internals and is simply wrong for "you
-- are not allowed to see this." auth.jwt()->>'org_id' on a token with no such
-- claim returns SQL NULL cleanly (confirmed directly against this project's
-- local Postgres: auth.jwt() is defined with current_setting(..., true) —
-- the missing_ok form), and NULL::uuid from casting that is also NULL, and
-- `organization_id = NULL` is NULL, which USING/WITH CHECK treat as false.
-- Net effect: zero rows, no error. That is the actual fix here, not just a
-- source swap.
-- ============================================================================
-- LOCATION SCOPING — new in this migration
-- ============================================================================
-- app_role = 'owner' sees the whole org; app_role = 'front_desk' is scoped to
-- their own location_id (users.location_id, carried onto the token by the
-- hook). Only `members` carries location_id directly; memberships,
-- attendance and whatsapp_messages reach it through member_id -> members.
-- location_id (an EXISTS subquery), and payments gets no location carve-out
-- at all — see the per-table comments below for the reasoning on each.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- organizations — checks id, not organization_id: this table IS the tenant
-- root. No location scoping (an org, not a location, is the unit here).
-- ---------------------------------------------------------------------------
DROP POLICY tenant_isolation_orgs ON organizations;
CREATE POLICY tenant_isolation_orgs ON organizations
  USING (id = (auth.jwt() ->> 'org_id')::uuid);

-- ---------------------------------------------------------------------------
-- locations — front_desk sees only their own location row; owner sees every
-- location in the org. Matches users.location_id's own semantics (NULL for
-- owner = "not tied to a branch" = sees all; set for front_desk = one).
-- ---------------------------------------------------------------------------
DROP POLICY tenant_isolation_locations ON locations;
CREATE POLICY tenant_isolation_locations ON locations
  USING (
    organization_id = (auth.jwt() ->> 'org_id')::uuid
    AND (
      (auth.jwt() ->> 'app_role') = 'owner'
      OR id = (auth.jwt() ->> 'location_id')::uuid
    )
  );

-- ---------------------------------------------------------------------------
-- users — org-scoped only, for correctness/service_role/future-proofing.
-- Deliberately not location-scoped and, as of this migration, `authenticated`
-- still has no GRANT on this table at all (see the companion revoke/grant
-- migration) — so this policy is a no-op for staff sessions today. It exists
-- so the table's own tenant boundary is expressed correctly regardless of
-- what future grants add, rather than leaving the old dead current_setting
-- form in place on the one table that holds pin_hash.
-- ---------------------------------------------------------------------------
DROP POLICY tenant_isolation_users ON users;
CREATE POLICY tenant_isolation_users ON users
  USING (organization_id = (auth.jwt() ->> 'org_id')::uuid);

-- ---------------------------------------------------------------------------
-- members — location_id lives directly on this table. WITH CHECK mirrors
-- USING: this is one of the two tables `authenticated` can write to directly
-- (see the companion grant migration), so both read and write need the same
-- scoping enforced.
-- ---------------------------------------------------------------------------
DROP POLICY tenant_isolation_members ON members;
CREATE POLICY tenant_isolation_members ON members
  USING (
    organization_id = (auth.jwt() ->> 'org_id')::uuid
    AND (
      (auth.jwt() ->> 'app_role') = 'owner'
      OR location_id = (auth.jwt() ->> 'location_id')::uuid
    )
  )
  WITH CHECK (
    organization_id = (auth.jwt() ->> 'org_id')::uuid
    AND (
      (auth.jwt() ->> 'app_role') = 'owner'
      OR location_id = (auth.jwt() ->> 'location_id')::uuid
    )
  );

-- ---------------------------------------------------------------------------
-- membership_plans — org-scope only. Front_desk needs plan prices to quote
-- members ("your plan renews at ₹1500"); plans have no location dimension in
-- this schema (one plan catalog per org, shared across all its locations).
-- ---------------------------------------------------------------------------
DROP POLICY tenant_isolation_plans ON membership_plans;
CREATE POLICY tenant_isolation_plans ON membership_plans
  USING (organization_id = (auth.jwt() ->> 'org_id')::uuid);

-- ---------------------------------------------------------------------------
-- memberships — no location_id column; reached through member_id ->
-- members.location_id. WITH CHECK mirrors USING (the other table
-- `authenticated` can write to directly).
-- ---------------------------------------------------------------------------
DROP POLICY tenant_isolation_memberships ON memberships;
CREATE POLICY tenant_isolation_memberships ON memberships
  USING (
    organization_id = (auth.jwt() ->> 'org_id')::uuid
    AND (
      (auth.jwt() ->> 'app_role') = 'owner'
      OR EXISTS (
        SELECT 1 FROM members m
         WHERE m.id = memberships.member_id
           AND m.location_id = (auth.jwt() ->> 'location_id')::uuid
      )
    )
  )
  WITH CHECK (
    organization_id = (auth.jwt() ->> 'org_id')::uuid
    AND (
      (auth.jwt() ->> 'app_role') = 'owner'
      OR EXISTS (
        SELECT 1 FROM members m
         WHERE m.id = memberships.member_id
           AND m.location_id = (auth.jwt() ->> 'location_id')::uuid
      )
    )
  );

-- ---------------------------------------------------------------------------
-- payments — owner-only, full deny for front_desk, no location carve-out at
-- all. Payments have no location dimension in the schema (only
-- organization_id + membership_id), and payment history is exactly the kind
-- of financial detail a front-desk PIN should not expose. This is
-- defense-in-depth on top of the grant boundary, not the only line of
-- defense — see the companion migration for the GRANT side.
-- ---------------------------------------------------------------------------
DROP POLICY tenant_isolation_payments ON payments;
CREATE POLICY tenant_isolation_payments ON payments
  USING (
    organization_id = (auth.jwt() ->> 'org_id')::uuid
    AND (auth.jwt() ->> 'app_role') = 'owner'
  );

-- ---------------------------------------------------------------------------
-- attendance — no location_id column; reached through member_id ->
-- members.location_id, same shape as memberships above.
-- ---------------------------------------------------------------------------
DROP POLICY tenant_isolation_attendance ON attendance;
CREATE POLICY tenant_isolation_attendance ON attendance
  USING (
    organization_id = (auth.jwt() ->> 'org_id')::uuid
    AND (
      (auth.jwt() ->> 'app_role') = 'owner'
      OR EXISTS (
        SELECT 1 FROM members m
         WHERE m.id = attendance.member_id
           AND m.location_id = (auth.jwt() ->> 'location_id')::uuid
      )
    )
  );

-- ---------------------------------------------------------------------------
-- whatsapp_messages — member-tied rows scoped like attendance/memberships.
-- member_id IS NULL rows are the daily-owner-brief broadcasts (see
-- daily-owner-brief/index.ts's own header note on why member_id is NULL
-- there) — strategic/financial summary content sent to the owner's phone,
-- not day-to-day member-interaction history a front-desk operator has any
-- operational reason to read. Those stay owner-only regardless of location.
-- ---------------------------------------------------------------------------
DROP POLICY tenant_isolation_wa_messages ON whatsapp_messages;
CREATE POLICY tenant_isolation_wa_messages ON whatsapp_messages
  USING (
    organization_id = (auth.jwt() ->> 'org_id')::uuid
    AND (
      (auth.jwt() ->> 'app_role') = 'owner'
      OR (
        member_id IS NOT NULL
        AND EXISTS (
          SELECT 1 FROM members m
           WHERE m.id = whatsapp_messages.member_id
             AND m.location_id = (auth.jwt() ->> 'location_id')::uuid
        )
      )
    )
  );

-- ---------------------------------------------------------------------------
-- Supporting index — confirmed needed, not just a nice-to-have. Before this
-- migration, `members` had only its PK and the (organization_id, phone)
-- UNIQUE constraint; nothing touching location_id. Every policy above that
-- reaches members.location_id (directly, on members itself, or via the
-- EXISTS subqueries) benefits from it, and any query filtering members by
-- (organization_id, location_id) directly — e.g. a front-desk "list my
-- location's members" screen — would sequential-scan without it.
-- ---------------------------------------------------------------------------
CREATE INDEX idx_members_org_location ON members (organization_id, location_id);
