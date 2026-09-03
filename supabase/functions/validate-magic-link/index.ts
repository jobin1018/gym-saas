// validate-magic-link — redeem a coach's one-time WhatsApp magic-link token
// for a real coach session, no PIN.
//
// POST { token }
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
//     claim_coach_magic_link(token) (20260906090000), an atomic
//     `UPDATE coach_magic_links SET used_at = now() WHERE token = $1 AND
//     used_at IS NULL AND expires_at > now() RETURNING ...` entirely inside
//     Postgres. A second attempt updates zero rows. The claim happens BEFORE
//     the session is minted, so a mint failure burns the link (the coach
//     texts SESSION again) — an acceptable, rare cost to keep single-use
//     absolute.
//   * 15-minute expiry (set by the generator in whatsapp-webhook), decided by
//     Postgres's own now() inside claim_coach_magic_link — deliberately NOT
//     a timestamp computed here and passed in. See that migration's header
//     for why: a client-computed "now" makes the check depend on the edge
//     runtime's clock agreeing with Postgres's, which is one clock too many
//     for a security-critical comparison.
//   * SCOPED to one coach_user_id. The session this mints is that coach's
//     ordinary session — same app_role='coach', same org, same RLS. It is
//     minted the EXACT same way staff-login mints one (shared
//     ../_shared/staff-session.ts), not via a side path.
//
// WHAT AN ATTACKER CAN DO WITH A LEAKED, STILL-VALID LINK (before the coach
// uses it, within 15 min): establish ONE session as that coach and, within
// that coach's RLS scope, view their active client list and write a training
// note / body measurement for one of their actively-assigned members. That
// is the entire blast radius — no revenue data, no other coaches' clients, no
// member PII beyond what the coach already sees, no owner/staff-management
// capability, no PIN change. Any such write is attributable (the note's
// coach_id) and correctable. The coach_magic_links row is the audit trail.
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

interface CoachRow extends StaffSessionUser {
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
  //         (claim_coach_magic_link, 20260906090000). ---
  const { data: claimRows, error: claimErr } = await admin
    .rpc("claim_coach_magic_link", { p_token: token });

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

  // --- (b) The coach must still be a real, active coach. ---
  const { data: coach, error: coachErr } = await admin
    .from("users")
    .select("id, auth_user_id, name, role, organization_id, location_id, active")
    .eq("id", (claimed as any).coach_user_id)
    .maybeSingle();
  if (coachErr) throw coachErr;

  if (!coach || (coach as any).role !== "coach" || !(coach as any).active) {
    console.warn(
      `[${TAG}] token for coach ${(claimed as any).coach_user_id} redeemed but coach is ` +
        `${!coach ? "missing" : (coach as any).role !== "coach" ? "no longer a coach" : "deactivated"}.`,
    );
    return json({ ok: false, error: "coach_unavailable" }, 403);
  }
  const coachRow = coach as CoachRow;

  // --- (c) Mint the coach's ordinary session — same path as staff-login. ---
  try {
    const authUserId = await ensureAuthUser(admin, coachRow, TAG);
    await syncUserMetadata(admin, authUserId, coachRow, TAG);
    const anon = createAnonClient();
    const session = await mintSession(admin, anon, syntheticEmail(coachRow.id));

    console.log(
      `[${TAG}] link ${(claimed as any).link_id} redeemed -> session for coach ${coachRow.id} (org ${coachRow.organization_id})`,
    );

    return json({
      ok: true,
      access_token: session.accessToken,
      refresh_token: session.refreshToken,
      expires_in: session.expiresIn,
      token_type: session.tokenType,
      name: coachRow.name,
      role: coachRow.role,
      organization_id: coachRow.organization_id,
      location_id: coachRow.location_id,
    });
  } catch (err) {
    // The link is already consumed (claim happened first). This is a
    // provisioning failure, not an auth one — distinct code so the page can
    // say "try texting SESSION again" rather than "invalid link".
    console.error(`[${TAG}] session provisioning failed for coach ${coachRow.id}:`, err);
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
