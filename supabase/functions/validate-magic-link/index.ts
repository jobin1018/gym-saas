// validate-magic-link — redeem a one-time WhatsApp magic-link token for a
// real staff session (coach, owner or front_desk), no PIN.
//
// POST { token }
//
// ============================================================================
// GENERALIZED (20260907090000): coach-only -> any staff role, by `purpose`
// ============================================================================
// staff_magic_links.purpose says what a link was generated for:
//   session_log     -> the coach quick-log page (original use, unchanged
//                       behaviour: role must be 'coach')
//   add_member      -> the ADD MEMBER page (role must be owner/front_desk)
//   add_pt_package  -> the ADD PT page      (role must be owner/front_desk)
// PURPOSE_ROLES below is the one place that mapping lives. `purpose` is
// returned alongside the session so the landing page knows which form to
// render — it is NOT an extra privilege boundary. The session minted here
// is an ORDINARY session for whichever role the link's user_id actually
// has, at that role's normal full RLS-governed privilege — identical to a
// PIN login. See 20260907090000's header for the full reasoning on why
// `purpose` is a UX/audit field, not a capability restriction: this app has
// no narrower-than-role capability model anywhere else, and inventing one
// only for magic-link sessions would be inconsistent, not safer. What every
// requirement here actually needs — a link can't be reused for something
// else — is already guaranteed by single-use alone: once claimed, for
// ANYTHING, the token is dead.
//
// ============================================================================
// WHY THIS IS SAFE DESPITE BYPASSING PIN AUTH
// ============================================================================
// The token IS the credential, so the whole model rests on the token being
// impossible to guess, impossible to reuse, and short-lived:
//
//   * 256 bits of entropy (crypto.getRandomValues, base64url) — brute force
//     is not on the table; a lookup miss is just `invalid_token`.
//   * SINGLE USE, enforced at the row: this function's first act is calling
//     claim_staff_magic_link(token) (20260906090000 / generalized in
//     20260907090000), an atomic `UPDATE staff_magic_links SET used_at =
//     now() WHERE token = $1 AND used_at IS NULL AND expires_at > now()
//     RETURNING ...` entirely inside Postgres. A second attempt updates zero
//     rows. The claim happens BEFORE the session is minted, so a mint
//     failure burns the link (the staffer re-sends the WhatsApp command) —
//     an acceptable, rare cost to keep single-use absolute.
//   * 15-minute expiry (set by the generator in whatsapp-webhook), decided by
//     Postgres's own now() inside claim_staff_magic_link — deliberately NOT
//     a timestamp computed here and passed in. See 20260906090000's header
//     for why: a client-computed "now" makes the check depend on the edge
//     runtime's clock agreeing with Postgres's, which is one clock too many
//     for a security-critical comparison.
//   * SCOPED to one user_id, and the role check below re-derives that user's
//     CURRENT role/active status from the database on every redemption — a
//     link generated for a since-demoted or deactivated user is refused, not
//     honoured. The session this mints is that user's ordinary session, same
//     org, same RLS. It is minted the EXACT same way staff-login mints one
//     (shared ../_shared/staff-session.ts), not via a side path.
//
// WHAT AN ATTACKER CAN DO WITH A LEAKED, STILL-VALID LINK (before the real
// staffer uses it, within 15 min): establish ONE session as that specific
// person and, within their normal RLS scope, do whatever that PIN login
// could do — a coach's client list and session notes; an owner's or
// front_desk's member/PT-package writes at their normal org/location scope.
// That is the entire blast radius: no capability beyond what the person's
// role already has, no other tenant, no PIN change (staff-pin-reset is
// unaffected by this table). Any write is attributable and correctable. The
// staff_magic_links row is the audit trail — generation and redemption both
// logged (whatsapp-webhook and here), same discipline as every other write
// in this system.
// ============================================================================

import "@supabase/functions-js/edge-runtime.d.ts";
import { createAdminClient, createAnonClient, type SupabaseClient } from "../_shared/supabase.ts";
import { corsJson as json, corsPreflightResponse } from "../_shared/cors.ts";
import {
  ensureAuthUser,
  mintSession,
  syncUserMetadata,
  syntheticEmail,
  type StaffSessionUser,
} from "../_shared/staff-session.ts";

const TAG = "validate-magic-link";
// base64url, the shape whatsapp-webhook's generator emits (32 bytes -> 43
// chars). A generous bound; anything outside it never hits the DB.
const TOKEN_RE = /^[A-Za-z0-9_-]{32,128}$/;

type Purpose = "session_log" | "add_member" | "add_pt_package";

// The only place "which role may redeem a link of this purpose" is decided.
const PURPOSE_ROLES: Record<Purpose, readonly string[]> = {
  session_log: ["coach"],
  add_member: ["owner", "front_desk"],
  add_pt_package: ["owner", "front_desk"],
};

interface StaffRow extends StaffSessionUser {
  organization_id: string;
  location_id: string | null;
  active: boolean;
}

async function handle(req: Request): Promise<Response> {
  let body: any;
  try {
    body = await req.json();
  } catch {
    return json({ ok: false, error: "invalid_json_body" }, 400);
  }

  const token = typeof body?.token === "string" ? body.token.trim() : "";
  if (!token || !TOKEN_RE.test(token)) {
    return json({ ok: false, error: "token_malformed" }, 400);
  }

  const admin = createAdminClient();

  // --- (a) Atomic single-use + expiry claim, entirely Postgres-clock-driven
  //         (claim_staff_magic_link, 20260906090000 / 20260907090000). ---
  const { data: claimRows, error: claimErr } = await admin
    .rpc("claim_staff_magic_link", { p_token: token });

  if (claimErr) throw claimErr;

  const claim = Array.isArray(claimRows) ? claimRows[0] : claimRows;

  if (!claim || claim.outcome !== "claimed") {
    switch (claim?.outcome) {
      case "not_found":     return json({ ok: false, error: "invalid_token" }, 404);
      case "expired":       return json({ ok: false, error: "link_expired" }, 410);
      case "already_used":
      default:              return json({ ok: false, error: "link_already_used" }, 410);
    }
  }
  const claimed = claim;
  const purpose = (claimed as any).purpose as Purpose;

  // --- (b) The user must still be real, active, and hold a role this
  //         purpose actually allows (re-checked live, not trusted from
  //         whenever the link was generated). ---
  const { data: user, error: userErr } = await admin
    .from("users")
    .select("id, auth_user_id, name, role, organization_id, location_id, active")
    .eq("id", (claimed as any).user_id)
    .maybeSingle();
  if (userErr) throw userErr;

  const allowedRoles = PURPOSE_ROLES[purpose] ?? [];
  if (!user || !allowedRoles.includes((user as any).role) || !(user as any).active) {
    console.warn(
      `[${TAG}] token (purpose=${purpose}) for user ${(claimed as any).user_id} redeemed but ` +
        `${!user ? "user is missing" : !(user as any).active ? "user is deactivated" : `role '${(user as any).role}' is not valid for ${purpose}`}.`,
    );
    return json({ ok: false, error: "staff_unavailable" }, 403);
  }
  const staffRow = user as StaffRow;

  // --- (c) Mint the user's ordinary session — same path as staff-login. ---
  try {
    const authUserId = await ensureAuthUser(admin, staffRow, TAG);
    await syncUserMetadata(admin, authUserId, staffRow, TAG);
    const anon = createAnonClient();
    const session = await mintSession(admin, anon, syntheticEmail(staffRow.id));

    console.log(
      `[${TAG}] link ${(claimed as any).link_id} (purpose=${purpose}) redeemed -> session for ` +
        `${staffRow.role} ${staffRow.id} (org ${staffRow.organization_id})`,
    );

    return json({
      ok: true,
      access_token: session.accessToken,
      refresh_token: session.refreshToken,
      expires_in: session.expiresIn,
      token_type: session.tokenType,
      name: staffRow.name,
      role: staffRow.role,
      organization_id: staffRow.organization_id,
      location_id: staffRow.location_id,
      purpose,
    });
  } catch (err) {
    // The link is already consumed (claim happened first). This is a
    // provisioning failure, not an auth one — distinct code so the page can
    // say "try requesting a new link" rather than "invalid link".
    console.error(`[${TAG}] session provisioning failed for ${staffRow.role} ${staffRow.id}:`, err);
    return json({ ok: false, error: "session_provisioning_failed" }, 500);
  }
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return corsPreflightResponse();
  if (req.method !== "POST") {
    return json({ ok: false, error: "method_not_allowed" }, 405);
  }
  try {
    return await handle(req);
  } catch (err) {
    console.error(`[${TAG}] unhandled failure:`, err);
    return json({
      ok: false,
      error: "internal_error",
      detail: err instanceof Error ? err.message : String(err),
    }, 500);
  }
});
