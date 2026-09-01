// staff-manage — an OWNER creates / edits / deactivates / reactivates a staff
// member in their OWN organization.
//
// POST { action: "create" | "edit" | "deactivate" | "reactivate", ... }
// Authorization: Bearer <the owner's own staff-login access token>
//
// ============================================================================
// "edit" — name / phone / role / location_id ONLY
// ============================================================================
// The PIN is deliberately NOT editable through this path. PIN changes go
// exclusively through staff-pin-reset (rate-limit ledger reset, its own audit
// line). `pin` / `pin_hash` in an edit payload are ignored, never written.
//
// ROLE CHANGE AWAY FROM 'coach' WITH ACTIVE PACKAGES — BLOCKED. If the target
// is currently a coach and still has pt_packages at status='active', the edit
// is refused (409 coach_has_active_packages, with the count). Reason: the
// pt_packages_validate_refs trigger enforces "coach_id must be an active
// coach" on every write to that table, so silently orphaning those rows makes
// them un-updatable (can't mark completed, can't edit) until coach_id is
// repointed — and an active package is a paid, in-progress client
// relationship, not just a dangling FK. The owner must reassign or complete
// those packages first. Completed / cancelled packages do NOT block.
//
// ============================================================================
// TRUST MODEL — identical to staff-pin-reset
// ============================================================================
// Called by a logged-in owner from the admin UI (a browser). The only
// credential is the caller's own staff session token. verify_jwt = true
// (config.toml) stops keyless/garbage at the gateway; this function then
// RE-validates the token via admin.auth.getUser(token) and reads the caller's
// role / organization_id / active FROM public.users, never from the token's
// custom claims. A stale or forged claim cannot act.
//
// resolveCaller() is deliberately a near-copy of staff-pin-reset's — same
// "NOTE ON DUPLICATION" call the shared helpers already make elsewhere. The
// one addition here and there: the caller must also be active = true, so a
// just-deactivated owner (whose access token has not expired yet) cannot keep
// managing staff.
//
// ============================================================================
// SESSION REVOCATION ON DEACTIVATE
// ============================================================================
// Setting users.active = false does three things together (see
// 20260901090000):
//   - staff-login refuses a new session for them;
//   - custom_access_token_hook strips tenant claims on their next token
//     refresh, so RLS denies everything;
//   - THIS function also calls auth.admin.signOut(auth_user_id, 'global'),
//     which invalidates their refresh token immediately.
// Their current *access* token (stateless JWT) still works until it expires —
// jwt_expiry is 3600s, so the worst-case residual window is <= 1 hour, and in
// practice far shorter because the client refreshes proactively and the
// refreshed token is already dead. That residual window is the accepted
// exposure; there is no server-side way to kill an already-issued JWT.
// ============================================================================

import "@supabase/functions-js/edge-runtime.d.ts";
import bcrypt from "bcryptjs";
import { createAdminClient, type SupabaseClient } from "../_shared/supabase.ts";
import { corsJson as json, corsPreflightResponse } from "../_shared/cors.ts";

const TAG = "staff-manage";
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const PIN_RE = /^\d{4,8}$/; // same keyspace as staff-login / staff-pin-reset
const PHONE_RE = /^\d{7,15}$/; // loosely E.164, matches staff-lookup-by-phone
const BCRYPT_COST = 12;
const ROLES = ["owner", "front_desk", "coach"] as const;

interface CallerUser {
  id: string;
  organization_id: string;
  role: string;
  active: boolean;
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

  const { data, error } = await admin.auth.getUser(bearer);
  if (error || !data?.user) return null;

  const { data: row, error: rowErr } = await admin
    .from("users")
    .select("id, organization_id, role, active")
    .eq("auth_user_id", data.user.id)
    .maybeSingle();

  if (rowErr) throw rowErr;
  if (!row) return null;

  return row as CallerUser;
}

// ---------------------------------------------------------------------------
// Actions
// ---------------------------------------------------------------------------

async function doCreate(
  admin: SupabaseClient,
  caller: CallerUser,
  body: any,
): Promise<Response> {
  const name = typeof body?.name === "string" ? body.name.trim() : "";
  const phone = typeof body?.phone === "string" ? body.phone.replace(/\D/g, "") : "";
  const role = typeof body?.role === "string" ? body.role.trim() : "";
  const pin = typeof body?.pin === "string" ? body.pin.trim() : "";
  const locationId = typeof body?.location_id === "string" && body.location_id.trim()
    ? body.location_id.trim()
    : null;

  if (!name) return json({ ok: false, error: "name_required" }, 400);
  if (!PHONE_RE.test(phone)) {
    return json({ ok: false, error: "phone_malformed", detail: "expected 7-15 digits" }, 400);
  }
  if (!(ROLES as readonly string[]).includes(role)) {
    return json({ ok: false, error: "role_invalid", detail: `one of ${ROLES.join("/")}` }, 400);
  }
  if (!PIN_RE.test(pin)) {
    return json({ ok: false, error: "pin_malformed", detail: "expected 4-8 digits" }, 400);
  }

  // Owners are not tied to a branch (users.location_id NULL, matching the
  // seed convention); front_desk / coach MUST be, and to a branch of the
  // caller's own org.
  if (role === "owner") {
    if (locationId) {
      return json({ ok: false, error: "owner_has_no_location" }, 400);
    }
  } else {
    if (!locationId || !UUID_RE.test(locationId)) {
      return json({ ok: false, error: "location_id_required", detail: `for role ${role}` }, 400);
    }
    const locErr = await assertLocationInOrg(admin, caller, locationId);
    if (locErr) return locErr;
  }

  const pinHash = await bcrypt.hash(pin, BCRYPT_COST);

  const { data: created, error: insErr } = await admin
    .from("users")
    .insert({
      organization_id: caller.organization_id,
      name,
      phone,
      role,
      location_id: locationId,
      pin_hash: pinHash,
      active: true,
    })
    .select("id")
    .maybeSingle();

  if (insErr) {
    // UNIQUE (organization_id, phone)
    if ((insErr as any).code === "23505") {
      return json({ ok: false, error: "phone_already_in_org" }, 409);
    }
    throw insErr;
  }

  console.log(`[${TAG}] owner ${caller.id} created ${role} ${(created as any).id} (org ${caller.organization_id})`);
  return json({ ok: true, action: "create", user_id: (created as any).id });
}

interface TargetUser {
  id: string;
  auth_user_id: string | null;
  active: boolean;
  role: string;
  name: string;
  phone: string;
  location_id: string | null;
}

async function loadSameOrgTarget(
  admin: SupabaseClient,
  caller: CallerUser,
  body: any,
): Promise<TargetUser | Response> {
  const targetId = typeof body?.target_user_id === "string" ? body.target_user_id.trim() : "";
  if (!targetId || !UUID_RE.test(targetId)) {
    return json({ ok: false, error: "target_user_id_malformed" }, 400);
  }
  const { data: target, error } = await admin
    .from("users")
    .select("id, organization_id, auth_user_id, active, role, name, phone, location_id")
    .eq("id", targetId)
    .maybeSingle();
  if (error) throw error;

  // Same answer for "no such user" and "user in another org" — an owner has
  // no business probing other tenants.
  if (!target || (target as any).organization_id !== caller.organization_id) {
    return json({ ok: false, error: "target_not_found" }, 404);
  }
  return {
    id: (target as any).id,
    auth_user_id: (target as any).auth_user_id ?? null,
    active: (target as any).active,
    role: (target as any).role,
    name: (target as any).name,
    phone: (target as any).phone,
    location_id: (target as any).location_id ?? null,
  };
}

/**
 * Validate a location_id belongs to the caller's org. Returns null on success,
 * or the error Response. Shared by doCreate and doEdit.
 */
async function assertLocationInOrg(
  admin: SupabaseClient,
  caller: CallerUser,
  locationId: string,
): Promise<Response | null> {
  const { data: loc, error: locErr } = await admin
    .from("locations")
    .select("id, organization_id")
    .eq("id", locationId)
    .maybeSingle();
  if (locErr) throw locErr;
  if (!loc || (loc as any).organization_id !== caller.organization_id) {
    return json({ ok: false, error: "location_not_in_org" }, 400);
  }
  return null;
}

async function doEdit(
  admin: SupabaseClient,
  caller: CallerUser,
  body: any,
): Promise<Response> {
  const target = await loadSameOrgTarget(admin, caller, body);
  if (target instanceof Response) return target;

  // Only these four are editable here. `pin` / `pin_hash` are intentionally
  // never read — see the header.
  const hasName = typeof body?.name === "string";
  const hasPhone = typeof body?.phone === "string";
  const hasRole = typeof body?.role === "string";
  const hasLocation = "location_id" in (body ?? {});
  if (!hasName && !hasPhone && !hasRole && !hasLocation) {
    return json({ ok: false, error: "no_editable_fields", detail: "name|phone|role|location_id" }, 400);
  }

  const patch: Record<string, unknown> = {};

  if (hasName) {
    const name = String(body.name).trim();
    if (!name) return json({ ok: false, error: "name_required" }, 400);
    patch.name = name;
  }

  if (hasPhone) {
    const phone = String(body.phone).replace(/\D/g, "");
    if (!PHONE_RE.test(phone)) {
      return json({ ok: false, error: "phone_malformed", detail: "expected 7-15 digits" }, 400);
    }
    patch.phone = phone;
  }

  // Resolve the *effective* role and location after this edit, then apply the
  // same owner-has-no-location / non-owner-needs-one invariant doCreate uses.
  const finalRole = hasRole ? String(body.role).trim() : target.role;
  if (hasRole && !(ROLES as readonly string[]).includes(finalRole)) {
    return json({ ok: false, error: "role_invalid", detail: `one of ${ROLES.join("/")}` }, 400);
  }

  let finalLocation: string | null = target.location_id;
  if (hasLocation) {
    const raw = body.location_id;
    finalLocation = typeof raw === "string" && raw.trim() ? raw.trim() : null;
  }
  if (finalRole === "owner") {
    finalLocation = null; // owners are never branch-scoped
  }

  if (finalRole === "owner") {
    if (hasLocation && body.location_id) {
      return json({ ok: false, error: "owner_has_no_location" }, 400);
    }
  } else {
    if (!finalLocation || !UUID_RE.test(finalLocation)) {
      return json({ ok: false, error: "location_id_required", detail: `for role ${finalRole}` }, 400);
    }
    const locErr = await assertLocationInOrg(admin, caller, finalLocation);
    if (locErr) return locErr;
  }

  if (hasRole || hasLocation) {
    patch.role = finalRole;
    patch.location_id = finalLocation;
  }

  // Role change away from coach while active packages exist — blocked. See header.
  if (target.role === "coach" && finalRole !== "coach") {
    const { count, error: cntErr } = await admin
      .from("pt_packages")
      .select("id", { count: "exact", head: true })
      .eq("coach_id", target.id)
      .eq("status", "active");
    if (cntErr) throw cntErr;
    if ((count ?? 0) > 0) {
      return json({
        ok: false,
        error: "coach_has_active_packages",
        active_package_count: count ?? 0,
        detail: "reassign or complete these packages before changing this coach's role",
      }, 409);
    }
  }

  const { error: updErr } = await admin
    .from("users")
    .update(patch)
    .eq("id", target.id)
    .eq("organization_id", caller.organization_id);
  if (updErr) {
    if ((updErr as any).code === "23505") {
      return json({ ok: false, error: "phone_already_in_org" }, 409);
    }
    throw updErr;
  }

  console.log(
    `[${TAG}] owner ${caller.id} edited ${target.id} (org ${caller.organization_id}) fields=${Object.keys(patch).join(",")}`,
  );
  return json({ ok: true, action: "edit", user_id: target.id, updated: Object.keys(patch) });
}

async function doSetActive(
  admin: SupabaseClient,
  caller: CallerUser,
  body: any,
  active: boolean,
): Promise<Response> {
  const target = await loadSameOrgTarget(admin, caller, body);
  if (target instanceof Response) return target;

  if (!active && target.id === caller.id) {
    // An owner deactivating themselves would lock themselves (and possibly
    // the whole org) out. Blocked outright.
    return json({ ok: false, error: "cannot_deactivate_self" }, 400);
  }

  const { error: updErr } = await admin
    .from("users")
    .update({ active })
    .eq("id", target.id)
    .eq("organization_id", caller.organization_id);
  if (updErr) throw updErr;

  let sessionRevoked: boolean | null = null;
  if (!active && target.auth_user_id) {
    // Kill the refresh token now so the stripped-claims hook (20260901090000)
    // fires on the very next client call, not just at natural expiry.
    const { error: signOutErr } = await admin.auth.admin.signOut(target.auth_user_id, "global");
    sessionRevoked = !signOutErr;
    if (signOutErr) {
      console.error(`[${TAG}] deactivated ${target.id} but signOut failed:`, signOutErr);
    }
  }

  console.log(
    `[${TAG}] owner ${caller.id} ${active ? "reactivated" : "deactivated"} ${target.id} ` +
      `(org ${caller.organization_id}${!active ? `, session_revoked=${sessionRevoked}` : ""})`,
  );
  return json({
    ok: true,
    action: active ? "reactivate" : "deactivate",
    user_id: target.id,
    ...(active ? {} : { session_revoked: sessionRevoked }),
  });
}

// ---------------------------------------------------------------------------
// Entry
// ---------------------------------------------------------------------------

async function handle(req: Request): Promise<Response> {
  let body: any;
  try {
    body = await req.json();
  } catch {
    return json({ ok: false, error: "invalid_json_body" }, 400);
  }

  const action = typeof body?.action === "string" ? body.action.trim() : "";
  if (!["create", "edit", "deactivate", "reactivate"].includes(action)) {
    return json({ ok: false, error: "action_invalid", detail: "create|edit|deactivate|reactivate" }, 400);
  }

  const admin = createAdminClient();

  const caller = await resolveCaller(admin, req);
  if (!caller) return json({ ok: false, error: "unauthenticated" }, 401);
  if (!caller.active) return json({ ok: false, error: "caller_deactivated" }, 403);
  if (caller.role !== "owner") return json({ ok: false, error: "not_owner" }, 403);

  switch (action) {
    case "create":
      return await doCreate(admin, caller, body);
    case "edit":
      return await doEdit(admin, caller, body);
    case "deactivate":
      return await doSetActive(admin, caller, body, false);
    case "reactivate":
      return await doSetActive(admin, caller, body, true);
    default:
      return json({ ok: false, error: "action_invalid" }, 400);
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
