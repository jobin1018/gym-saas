-- Generalize coach_magic_links into staff_magic_links — the same single-use,
-- 15-minute, Postgres-clock-authoritative token pattern, now reusable for
-- owner/front_desk entry points (ADD MEMBER, ADD PT) as well as the coach's
-- SESSION flow, instead of inventing a second mechanism per feature.
--
-- ============================================================================
-- WHY GENERALIZE THE EXISTING TABLE, NOT BUILD A SECOND ONE
-- ============================================================================
-- A shared table with a `purpose` discriminator is the right shape here, not
-- a wrong one to talk out of: every property that makes this table safe —
-- 256-bit unguessable token, single-use claimed atomically, 15-minute expiry
-- decided by Postgres's own clock (20260906090000), RLS deny-all with
-- service_role the only writer, one row per link as the audit trail — is
-- IDENTICAL across "log a PT session", "add a member" and "add a PT
-- package". Duplicating the table (and claim_coach_magic_link, and
-- validate-magic-link's whole claim path) three more times would mean four
-- copies of the exact same security-critical logic to keep in sync, which is
-- a worse outcome than one shared implementation plus a column that says
-- what a given link is FOR.
--
-- `purpose` is a UX/audit-trail field, NOT an extra privilege boundary. Once
-- a link is redeemed, it mints an ordinary session for the SAME role
-- (owner/front_desk/coach) the generating phone already resolves to — at
-- that role's normal, full RLS-governed privilege level, identical to what a
-- PIN login would grant. Restricting an "add_member"-purpose SESSION to only
-- ever write to `members` would be a NEW, narrower capability model that
-- doesn't exist anywhere else in this app (a PIN-logged-in owner can already
-- do everything their role allows, every time) — inventing one here would be
-- inconsistent, not safer. What `purpose` DOES guarantee, and the only thing
-- the stated requirement ("an ADD MEMBER link can't be reused to log a PT
-- session") actually needs: the token is single-use full stop — once
-- claimed, for ANYTHING, it is dead — and the frontend page reads `purpose`
-- back from the claim response to know which form to render. There is no
-- client-suppliable override of `purpose`; it is set once, server-side, at
-- generation time.
-- ============================================================================

ALTER TABLE public.coach_magic_links RENAME TO staff_magic_links;
ALTER TABLE public.staff_magic_links RENAME COLUMN coach_user_id TO user_id;
ALTER INDEX public.idx_coach_magic_links_coach RENAME TO idx_staff_magic_links_user;
ALTER TABLE public.staff_magic_links RENAME CONSTRAINT coach_magic_links_pkey TO staff_magic_links_pkey;
ALTER TABLE public.staff_magic_links RENAME CONSTRAINT coach_magic_links_token_key TO staff_magic_links_token_key;
ALTER TABLE public.staff_magic_links RENAME CONSTRAINT coach_magic_links_coach_user_id_fkey TO staff_magic_links_user_id_fkey;
ALTER TABLE public.staff_magic_links RENAME CONSTRAINT coach_magic_links_organization_id_fkey TO staff_magic_links_organization_id_fkey;

ALTER TABLE public.staff_magic_links ADD COLUMN purpose TEXT;
UPDATE public.staff_magic_links SET purpose = 'session_log' WHERE purpose IS NULL;
ALTER TABLE public.staff_magic_links ALTER COLUMN purpose SET NOT NULL;
ALTER TABLE public.staff_magic_links ADD CONSTRAINT staff_magic_links_purpose_check
  CHECK (purpose IN ('session_log', 'add_member', 'add_pt_package'));

COMMENT ON TABLE public.staff_magic_links IS
  'Short-lived, single-use tokens that let ANY staff role (coach, owner, '
  'front_desk) start a session from WhatsApp without their PIN, scoped by '
  'purpose (session_log | add_member | add_pt_package). See '
  '20260901092000 (original shape), 20260906090000 (Postgres-clock-'
  'authoritative claim) and this migration''s header for the full history. '
  'RLS is ENABLED with NO policy: deny-all for anon/authenticated; only '
  'service_role (validate-magic-link, whatsapp-webhook) ever touches it.';

-- ---------------------------------------------------------------------------
-- claim_staff_magic_link() — same body as claim_coach_magic_link
-- (20260906090000), renamed and widened to return `purpose` alongside the
-- claim outcome so validate-magic-link knows both WHO this session is for
-- and WHAT it was generated to do, without a second query.
-- ---------------------------------------------------------------------------
DROP FUNCTION public.claim_coach_magic_link(text);

CREATE FUNCTION public.claim_staff_magic_link(p_token text)
RETURNS TABLE(
  outcome         text,   -- 'claimed' | 'not_found' | 'already_used' | 'expired'
  link_id         uuid,
  user_id         uuid,
  organization_id uuid,
  purpose         text
)
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_link_id uuid;
  v_user    uuid;
  v_org     uuid;
  v_purpose text;
  v_used_at timestamptz;
  v_expires timestamptz;
BEGIN
  UPDATE public.staff_magic_links sml
     SET used_at = now()
   WHERE sml.token = p_token
     AND sml.used_at IS NULL
     AND sml.expires_at > now()
   RETURNING sml.id, sml.user_id, sml.organization_id, sml.purpose
    INTO v_link_id, v_user, v_org, v_purpose;

  IF FOUND THEN
    RETURN QUERY SELECT 'claimed'::text, v_link_id, v_user, v_org, v_purpose;
    RETURN;
  END IF;

  SELECT sml.id, sml.used_at, sml.expires_at
    INTO v_link_id, v_used_at, v_expires
    FROM public.staff_magic_links sml
   WHERE sml.token = p_token;

  IF NOT FOUND THEN
    RETURN QUERY SELECT 'not_found'::text, NULL::uuid, NULL::uuid, NULL::uuid, NULL::text;
  ELSIF v_used_at IS NOT NULL THEN
    RETURN QUERY SELECT 'already_used'::text, v_link_id, NULL::uuid, NULL::uuid, NULL::text;
  ELSIF v_expires <= now() THEN
    RETURN QUERY SELECT 'expired'::text, v_link_id, NULL::uuid, NULL::uuid, NULL::text;
  ELSE
    RETURN QUERY SELECT 'already_used'::text, v_link_id, NULL::uuid, NULL::uuid, NULL::text;
  END IF;
END;
$function$;

COMMENT ON FUNCTION public.claim_staff_magic_link(text) IS
  'Atomic single-use + expiry claim for a staff magic link (any purpose), '
  'decided entirely by Postgres''s own now() — no client-supplied '
  'timestamp. service_role only; RLS on staff_magic_links is deny-all '
  'otherwise, so this function is the only write path besides the row''s '
  'own INSERT in whatsapp-webhook.';

REVOKE ALL ON FUNCTION public.claim_staff_magic_link(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.claim_staff_magic_link(text) TO service_role;
