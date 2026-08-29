-- Grant SELECT on coaches_directory to authenticated only. Owner and
-- front_desk are the only real callers (populating the "assign coach"
-- dropdown on Members); a coach session has no reason to query it, but
-- there is nothing sensitive in id/name to withhold from that role either,
-- so this is a plain `authenticated` grant rather than a role-conditional
-- one — same breadth as organizations_for_client's grant, narrower than
-- granting anon (there is no pre-login use for this view, unlike
-- staff_lookup_directory).
GRANT SELECT ON public.coaches_directory TO authenticated;
