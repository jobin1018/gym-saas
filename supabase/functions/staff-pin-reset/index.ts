// staff-pin-reset — an OWNER resets a staff member's PIN (same-org only).
//
// POST { target_user_id, new_pin }
// Authorization: Bearer <the owner's own staff-login access token>
//
// ============================================================================
// TRUST MODEL — nothing from the client is trusted, not even the JWT claims
// ============================================================================
// This is called by a logged-in owner from the admin UI (a browser), so the
// only credential the caller holds is their own staff session token. That
// makes it the mirror image of staff-login (pre-login, anon key) and unlike
// renewal-scan / mark-overdue (service-to-service, service_role key): the gate
// here is the caller's real session.
//
// verify_jwt = true (config.toml) rejects keyless/garbage at the gateway, but
// this function does NOT then decode-and-trust the token's custom claims
// (org_id / app_role). Instead it:
//   1. re-validates the bearer token via admin.auth.getUser(token) — GoTrue
//      confirms it is a live, unexpired session and yields the auth uid;
//   2. looks up public.users WHERE auth_user_id = <that uid> and reads role
//      and organization_id FROM THE DATABASE, not from the token.
// So a stale or hand-crafted claim cannot act — "is the caller an owner, and
// of which org" is answered by the users table every time.
//
// ============================================================================
// SAME-ORG ENFORCEMENT — "an owner", not "any owner anywhere"
// ============================================================================
// The target user is looked up and its organization_id compared to the
// caller's. A mismatch (or no such user) returns the SAME 404 — an owner has
// no business learning whether a given user id exists in some other org. The
// pin_hash UPDATE additionally carries `AND organization_id = <caller org>` in
// its WHERE as defence in depth.
//
// ============================================================================
// PIN HASHING — server-side, always
// ============================================================================
// The browser sends the raw new PIN over TLS; bcrypt (cost 12, same as
// staff-login and seed.sql) runs here. A hash is never accepted from the
// client — identical discipline to staff-login's compare path.
//
// ============================================================================
// LOCKOUT RECOVERY
// ============================================================================
// A PIN reset is frequently how a locked-out staffer is recovered, so on
// success this also DELETEs their recent rows from login_attempts (scoped to
// the target's organization_id + phone), clearing the fixed lockout window so
// the new PIN works immediately rather than after the 15-minute cooldown.
// ============================================================================

import "@supabase/functions-js/edge-runtime.d.ts";
import bcrypt from "bcryptjs";
import { createAdminClient, type SupabaseClient } from "../_shared/supabase.ts";
import { corsJson as json, corsPreflightResponse } from "../_shared/cors.ts";

const TAG = "staff-pin-reset";
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const PIN_RE = /^\d{4,8}$/; // same keyspace as staff-login
const BCRYPT_COST = 12;

interface CallerUser {
  id: string;
  organization_id: string;
  role: string;
  active: boolean;
}

interface TargetUser {
  id: string;
  organization_id: string;
  phone: string;
}

/** Re-validate the bearer token and resolve the caller's public.users row. */
async function resolveCaller(
  admin: SupabaseClient,
  req: Request,
): Promise<CallerUser | null> {
  const bearer = (req.headers.get("authorization") ?? "")
    .replace(/^bearer\s+/i, "")
    .trim();
  if (!bearer) return null;

  // getUser(jwt) asks GoTrue to validate this exact token.
  const { data, error } = await admin.auth.getUser(bearer);
  if (error || !data?.user) return null;

  const { data: row, error: rowErr } = await admin
    .from("users")
    .select("id, organization_id, role, active")
    .eq("auth_user_id", data.user.id)
    .maybeSingle();

  if (rowErr) throw rowErr;
  if (!row) return null; // bridged row gone — treat as unauthenticated

  return row as CallerUser;
}

async function handleReset(req: Request): Promise<Response> {
  let body: any;
  try {
    body = await req.json();
  } catch {
    return json({ ok: false, error: "invalid_json_body" }, 400);
  }

  const targetUserId = typeof body?.target_user_id === "string"
    ? body.target_user_id.trim()
    : "";
  const newPin = typeof body?.new_pin === "string" ? body.new_pin.trim() : "";

  if (!targetUserId || !UUID_RE.test(targetUserId)) {
    return json({ ok: false, error: "target_user_id_malformed" }, 400);
  }
  if (!newPin) {
    return json({ ok: false, error: "new_pin_required" }, 400);
  }
  if (!PIN_RE.test(newPin)) {
    return json({ ok: false, error: "pin_malformed", detail: "expected 4-8 digits" }, 400);
  }

  const admin = createAdminClient();

  // --- (a) Who is calling, really? ---
  const caller = await resolveCaller(admin, req);
  if (!caller) {
    return json({ ok: false, error: "unauthenticated" }, 401);
  }
  // A just-deactivated owner whose access token has not expired must not keep
  // acting (users.active added in 20260901090000).
  if (!caller.active) {
    return json({ ok: false, error: "caller_deactivated" }, 403);
  }
  if (caller.role !== "owner") {
    return json({ ok: false, error: "not_owner" }, 403);
  }

  // --- (b) The target must be a real user in the caller's own org. ---
  const { data: target, error: targetErr } = await admin
    .from("users")
    .select("id, organization_id, phone")
    .eq("id", targetUserId)
    .maybeSingle();

  if (targetErr) throw targetErr;

  if (!target || (target as TargetUser).organization_id !== caller.organization_id) {
    // Same answer for "no such user" and "user in another org": an owner has
    // no business probing other tenants.
    return json({ ok: false, error: "target_not_found" }, 404);
  }

  const targetUser = target as TargetUser;

  // --- (c) Hash server-side and write, re-scoped by org in the WHERE. ---
  const pinHash = await bcrypt.hash(newPin, BCRYPT_COST);

  const { error: updateErr } = await admin
    .from("users")
    .update({ pin_hash: pinHash })
    .eq("id", targetUser.id)
    .eq("organization_id", caller.organization_id);

  if (updateErr) throw updateErr;

  // --- (d) Clear the lockout window so the new PIN works immediately. ---
  const { error: lockoutErr } = await admin
    .from("login_attempts")
    .delete()
    .eq("organization_id", caller.organization_id)
    .eq("phone", targetUser.phone);

  if (lockoutErr) {
    // The PIN is already reset; a stale lockout row just means the staffer
    // waits out the window. Loud log, not a failure response.
    console.error(`[${TAG}] pin reset for ${targetUser.id} ok, but clearing login_attempts failed:`, lockoutErr);
  }

  console.log(`[${TAG}] owner ${caller.id} reset PIN for ${targetUser.id} (org ${caller.organization_id})`);

  return json({ ok: true, target_user_id: targetUser.id });
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return corsPreflightResponse();
  if (req.method !== "POST") {
    return json({ ok: false, error: "method_not_allowed" }, 405);
  }

  try {
    return await handleReset(req);
  } catch (err) {
    console.error(`[${TAG}] unhandled failure:`, err);
    return json({
      ok: false,
      error: "internal_error",
      detail: err instanceof Error ? err.message : String(err),
    }, 500);
  }
});
