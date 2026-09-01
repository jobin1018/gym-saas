-- staff_directory gains location_id — the owner Staff-edit UI (staff-manage's
-- new "edit" action) needs to pre-fill the location select for a coach /
-- front_desk row, and the view didn't carry it: it was created for the
-- read-only list + PIN-reset flow, before edit existed.
--
-- Same view, same WHERE (owner-only, org-scoped via auth.jwt()). Adding a
-- column to CREATE OR REPLACE VIEW is safe here because it is APPENDED —
-- Postgres requires the existing column list stay a strict prefix. location_id
-- is nullable (owners have none), so nothing that selects specific columns
-- from this view breaks.

CREATE OR REPLACE VIEW public.staff_directory AS
SELECT id, name, role, phone, active, location_id
FROM public.users
WHERE organization_id = ((auth.jwt() ->> 'org_id')::uuid)
  AND (auth.jwt() ->> 'app_role') = 'owner';
