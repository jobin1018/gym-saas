-- Grant for staff-manage's new "edit" action.
--
-- 20260901090500 gave service_role only `UPDATE (active)` on public.users,
-- deliberately — at the time staff-manage could only create / deactivate /
-- reactivate. The "edit" action (this change set) writes name / phone / role /
-- location_id, so it needs those four columns too, or every edit call 42501s
-- ("permission denied for table users").
--
-- Same column-scoped, least-privilege discipline as every other users grant:
-- exactly the columns doEdit() writes, nothing else. pin_hash is NOT here on
-- purpose — PIN changes stay exclusively with staff-pin-reset (which has its
-- own `UPDATE (pin_hash)` grant from 20260829102500), and doEdit() never reads
-- or writes pin_hash regardless of what a payload contains.

GRANT UPDATE (name, phone, role, location_id) ON public.users TO service_role;
