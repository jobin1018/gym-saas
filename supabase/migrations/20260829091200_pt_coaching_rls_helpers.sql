-- SECURITY DEFINER helpers that break the members <-> pt_packages RLS cycle.
--
-- ============================================================================
-- THE CYCLE
-- ============================================================================
-- The coaching policies (20260829091500) need two cross-table lookups:
--   * members / training_notes / body_measurements must ask pt_packages
--     "is there an active assignment here"
--   * pt_packages (front_desk branch) must ask members "is this member at my
--     location"
-- Written as inline `EXISTS (SELECT ... FROM <other table>)`, those two
-- directions form a loop: evaluating the members policy expands the
-- pt_packages policy which expands the members policy again. Postgres aborts
-- that with `42P17 infinite recursion detected in policy for relation`.
--
-- ============================================================================
-- THE FIX — the standard Supabase pattern for this
-- ============================================================================
-- Move each lookup into a SECURITY DEFINER function. It runs as its owner
-- (postgres, superuser => RLS bypassed), so when a policy predicate calls it
-- the referenced table's OWN policy is not re-entered — the chain terminates.
-- Each function is a single STABLE existence check, reads nothing sensitive,
-- and is parameterised only by ids the caller already holds.
--
-- search_path pinned (SECURITY DEFINER discipline, same as
-- custom_access_token_hook and pt_packages_validate_refs). EXECUTE granted to
-- anon + authenticated because RLS predicates run as the querying role and
-- must be able to call them; anon still gets zero rows everywhere because the
-- policies that call these also require org_id/app_role/user_id claims an
-- anon token doesn't carry.
-- ============================================================================

-- "Is p_member a member at p_location" — for the pt_packages front_desk branch.
CREATE FUNCTION public.pt_member_at_location(p_member uuid, p_location uuid)
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public, pg_temp
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.members m
     WHERE m.id = p_member
       AND m.location_id = p_location
  );
$$;

-- "Does an ACTIVE package assign p_member to p_coach in p_org" — for the
-- members and body_measurements coach branches.
CREATE FUNCTION public.pt_active_assignment_exists(p_member uuid, p_coach uuid, p_org uuid)
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public, pg_temp
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.pt_packages p
     WHERE p.member_id = p_member
       AND p.coach_id  = p_coach
       AND p.organization_id = p_org
       AND p.status = 'active'
  );
$$;

-- Same, but also pins the specific package id — for training_notes, whose
-- rows carry pt_package_id and must not be attachable to some other package.
CREATE FUNCTION public.pt_active_package_match(
  p_package uuid, p_member uuid, p_coach uuid, p_org uuid)
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public, pg_temp
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.pt_packages p
     WHERE p.id = p_package
       AND p.member_id = p_member
       AND p.coach_id  = p_coach
       AND p.organization_id = p_org
       AND p.status = 'active'
  );
$$;

REVOKE ALL ON FUNCTION public.pt_member_at_location(uuid, uuid)              FROM PUBLIC;
REVOKE ALL ON FUNCTION public.pt_active_assignment_exists(uuid, uuid, uuid)  FROM PUBLIC;
REVOKE ALL ON FUNCTION public.pt_active_package_match(uuid, uuid, uuid, uuid) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.pt_member_at_location(uuid, uuid)              TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.pt_active_assignment_exists(uuid, uuid, uuid)  TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.pt_active_package_match(uuid, uuid, uuid, uuid) TO anon, authenticated;
