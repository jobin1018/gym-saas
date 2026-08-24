// staff-login — real PIN authentication, mints a genuine Supabase Auth session.
//
// POST { organization_id, phone, pin }
//
// Part 1 of 2 of replacing the placeholder PIN login. This function hashes
// nothing client-side (the browser only ever sends the raw PIN over TLS to
// here — pin_hash never leaves the database), rate-limits/locks out repeated
// failures, verifies the PIN with bcrypt, and — on success — bridges the
// caller into a real auth.users session via the Admin API. Part 2 (the
// custom-access-token hook + RLS rewrite that actually uses these sessions
// for tenant-scoped access) is separate follow-up work; this function does
// not touch RLS.
//
// ============================================================================
// WHY THIS FUNCTION IS DIFFERENT FROM send-renewal-reminder / renewal-scan
// ============================================================================
// Those require the SERVICE ROLE key from their caller (see
// ../_shared/auth.ts) because they are service-to-service and spend real
// money / send real messages. staff-login is the opposite: it is called
// directly by the frontend, PRE-login, so the only credential the caller can
// possibly hold is the public anon key. `verify_jwt = true` (set in
// config.toml) is still correct and sufficient here — the anon key IS a
// valid Supabase-issued JWT (role: anon), so the gateway still rejects
// garbage/keyless traffic before this code runs; there is no
// `authorizeServiceRole()` gate on top of it because there is no tighter
// credential a pre-login caller could present.
//
// Internally, this function uses the SERVICE ROLE key anyway
// (createAdminClient()) — it needs Admin API access (auth.admin.*) and has to
// bypass RLS to look up `users` across the lockout check, which is why the
// caller-facing trust boundary and the internal client are different things.
//
// ============================================================================
// WHY WRONG-PIN AND NOT-FOUND LOOK IDENTICAL
// ============================================================================
// A distinguishable response (different error, different timing, a 404 vs a
// 401) for "no such phone in this org" vs "wrong PIN for a real phone" would
// let an attacker enumerate which phone numbers are valid staff accounts —
// the same reason "invalid email or password" logins never say which half
// was wrong. Both paths return the exact same `invalid_credentials` body, AND
// both paths run a real bcrypt.compare() before answering (against
// DUMMY_PIN_HASH when there is no real hash to compare against) so the
// response TIME does not leak it either — bcrypt is deliberately slow, so
// skipping the compare on a fast "not found" path would be a timing oracle.
// ============================================================================

import "@supabase/functions-js/edge-runtime.d.ts";
import bcrypt from "bcryptjs";
import { createAdminClient, createAnonClient, type SupabaseClient } from "../_shared/supabase.ts";

const TAG = "staff-login";

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const PIN_RE = /^\d{4,8}$/;

const LOCKOUT_MINUTES = 15;

// A precomputed, fixed hash (cost 12) of a junk string that is not, and will
// never be, a real PIN. Never computed at request time — the whole point is
// that bcrypt.compare() against this costs exactly as much CPU time as
// comparing against a real user's hash, so a "no such user" response takes
// the same wall-clock time as a "wrong PIN" one. See the timing note above.
const DUMMY_PIN_HASH = "$2a$12$mLcIlAVv3xGKT9aAKamRUey2mMyiAy8SLF7ZV1rZOHq3TPm1j2WIC";

// ---------------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------------

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

/**
 * The non-deliverable email that bridges a phone-only staff user into
 * Supabase Auth, which is email-centric at the Admin API surface we need
 * (`generateLink({type:'magiclink'})`). `.invalid` is the RFC 2606 TLD
 * reserved for addresses that must never resolve — this is never emailed
 * anywhere; we only ever redeem the link token directly (see mintSession).
 */
function syntheticEmail(userId: string): string {
  return `${userId}@staff.internal.invalid`;
}

interface UserRow {
  id: string;
  organization_id: string;
  auth_user_id: string | null;
  name: string;
  role: string;
  location_id: string | null;
  pin_hash: string | null;
}

async function findUser(
  supabase: SupabaseClient,
  organizationId: string,
  phone: string,
): Promise<UserRow | null> {
  const { data, error } = await supabase
    .from("users")
    .select("id, organization_id, auth_user_id, name, role, location_id, pin_hash")
    .eq("organization_id", organizationId)
    .eq("phone", phone)
    .maybeSingle();

  if (error) throw error;

  return data;
}

// ---------------------------------------------------------------------------
// Rate limiting — both calls are thin wrappers over the SQL functions in
// 20260824130500_grant_service_role_staff_login.sql. See that migration for
// why this lives in Postgres (clock consistency, an advisory lock JS-side
// query-builder calls cannot take) rather than as two round trips from here.
// ---------------------------------------------------------------------------

interface LockoutStatus {
  locked: boolean;
  lockedUntil: Date | null;
}

async function checkLockout(
  supabase: SupabaseClient,
  organizationId: string,
  phone: string,
): Promise<LockoutStatus> {
  const { data, error } = await supabase
    .rpc("staff_login_lockout_status", {
      p_organization_id: organizationId,
      p_phone: phone,
    })
    .single();

  if (error) throw error;

  const row = data as { locked: boolean; locked_until: string | null };

  return {
    locked: row.locked,
    lockedUntil: row.locked_until ? new Date(row.locked_until) : null,
  };
}

/**
 * Record a real attempt (a PIN was actually evaluated). Deliberately NOT
 * called when a request is rejected purely because the account is already
 * locked — see the "FIXED WINDOW, NOT A RENEWING ONE" note in the grants
 * migration for why that distinction matters.
 */
async function recordAttempt(
  supabase: SupabaseClient,
  organizationId: string,
  phone: string,
  success: boolean,
): Promise<void> {
  const { error } = await supabase.rpc("staff_login_record_attempt", {
    p_organization_id: organizationId,
    p_phone: phone,
    p_success: success,
  });

  if (error) {
    // Never let a logging failure block the response — but a rate-limit
    // ledger that silently stops writing is a real problem, so this is
    // logged loudly rather than swallowed quietly.
    console.error(`[${TAG}] failed to record login attempt:`, error);
  }
}

// ---------------------------------------------------------------------------
// Auth bridge — auth.users provisioning + real session minting
// ---------------------------------------------------------------------------

/**
 * Returns the user's auth_user_id, creating the bridging auth.users row (and
 * writing it back) on first login. Compare-and-set on the write: if a
 * concurrent request already won, this returns THEIR auth_user_id and treats
 * the auth.users row just created here as a harmless orphan — same
 * acceptance as send-renewal-reminder's orphaned-Razorpay-link case. Never
 * two auth_user_id values in play for one users row.
 */
async function ensureAuthUser(admin: SupabaseClient, user: UserRow): Promise<string> {
  if (user.auth_user_id) return user.auth_user_id;

  const email = syntheticEmail(user.id);

  const { data: created, error: createErr } = await admin.auth.admin.createUser({
    email,
    email_confirm: true,
    user_metadata: { staff_user_id: user.id },
  });

  if (createErr || !created?.user) {
    throw new Error(`auth.admin.createUser failed: ${createErr?.message ?? "no user returned"}`);
  }

  const newAuthUserId = created.user.id;

  const { data: updated, error: updateErr } = await admin
    .from("users")
    .update({ auth_user_id: newAuthUserId })
    .eq("id", user.id)
    .is("auth_user_id", null)
    .select("auth_user_id")
    .maybeSingle();

  if (updateErr) throw updateErr;

  if (updated) return newAuthUserId; // we won the race

  // Lost the race — re-read the winner. Our freshly created auth.users row is
  // now unreferenced but harmless; nothing ever reads auth_user_id except by
  // following this same FK from `users`.
  const { data: winner, error: reReadErr } = await admin
    .from("users")
    .select("auth_user_id")
    .eq("id", user.id)
    .single();

  if (reReadErr || !winner?.auth_user_id) {
    throw new Error("lost the auth_user_id race but could not re-read the winner");
  }

  return winner.auth_user_id;
}

interface MintedSession {
  accessToken: string;
  refreshToken: string;
  expiresIn: number;
  tokenType: string;
}

/**
 * Mint a real session for `authUserId` via the Admin API, no password flow.
 *
 * admin.generateLink({type:'magiclink'}) creates the redeemable token
 * server-side (no email is actually sent — we never call signInWithOtp);
 * verifyOtp() redeems it. Redemption deliberately uses a SEPARATE anon-keyed
 * client, not the admin one — /verify is a public GoTrue endpoint gated on
 * `apikey` alone, and keeping the two clients distinct keeps "mint" (needs
 * service_role) and "redeem" (does not) visible in the code, matching how
 * the underlying REST API itself separates /admin/generate_link from
 * /verify. Verified empirically against this project's local gotrue before
 * this function was written — see the plan notes for the raw-REST smoke test
 * this mirrors.
 */
async function mintSession(
  admin: SupabaseClient,
  anon: SupabaseClient,
  email: string,
): Promise<MintedSession> {
  const { data: linkData, error: linkErr } = await admin.auth.admin.generateLink({
    type: "magiclink",
    email,
  });

  if (linkErr || !linkData) {
    throw new Error(`generateLink failed: ${linkErr?.message ?? "no data returned"}`);
  }

  const tokenHash = linkData.properties?.hashed_token;
  if (!tokenHash) {
    throw new Error("generateLink response missing properties.hashed_token");
  }

  const { data: verified, error: verifyErr } = await anon.auth.verifyOtp({
    token_hash: tokenHash,
    type: "magiclink",
  });

  if (verifyErr || !verified?.session) {
    throw new Error(`verifyOtp failed: ${verifyErr?.message ?? "no session returned"}`);
  }

  const { access_token, refresh_token, expires_in, token_type } = verified.session;

  return {
    accessToken: access_token,
    refreshToken: refresh_token,
    expiresIn: expires_in,
    tokenType: token_type,
  };
}

// ---------------------------------------------------------------------------
// Main flow
// ---------------------------------------------------------------------------

async function handleLogin(req: Request): Promise<Response> {
  let body: any;
  try {
    body = await req.json();
  } catch {
    return json({ ok: false, error: "invalid_json_body" }, 400);
  }

  const organizationId = typeof body?.organization_id === "string"
    ? body.organization_id.trim()
    : "";
  const phone = typeof body?.phone === "string" ? body.phone.trim() : "";
  const pin = typeof body?.pin === "string" ? body.pin.trim() : "";

  if (!organizationId) {
    return json({ ok: false, error: "organization_id_required" }, 400);
  }
  if (!UUID_RE.test(organizationId)) {
    return json({ ok: false, error: "organization_id_malformed", detail: `not a uuid: ${organizationId}` }, 400);
  }
  if (!phone) {
    return json({ ok: false, error: "phone_required" }, 400);
  }
  if (!pin) {
    return json({ ok: false, error: "pin_required" }, 400);
  }
  if (!PIN_RE.test(pin)) {
    return json({ ok: false, error: "pin_malformed", detail: "expected 4-8 digits" }, 400);
  }

  const admin = createAdminClient();

  // --- (a) Rate limit, BEFORE the PIN is even looked at. An account must be
  // --- lockable regardless of whether this particular attempt would have
  // --- been right or wrong.
  const lockout = await checkLockout(admin, organizationId, phone);

  if (lockout.locked) {
    const retryAfterSeconds = lockout.lockedUntil
      ? Math.max(0, Math.ceil((lockout.lockedUntil.getTime() - Date.now()) / 1000))
      : LOCKOUT_MINUTES * 60;

    // No attempt recorded here — see the fixed-window note on
    // staff_login_lockout_status() for why an already-locked rejection must
    // not itself count as a new failure.
    return json({ ok: false, error: "too_many_attempts", retry_after_seconds: retryAfterSeconds }, 429);
  }

  // --- (b) Look up the user, then verify the PIN either way — see the
  // --- module doc comment on why "not found" still runs a real bcrypt
  // --- compare instead of short-circuiting.
  const user = await findUser(admin, organizationId, phone);

  const pinMatches = await bcrypt.compare(pin, user?.pin_hash ?? DUMMY_PIN_HASH);

  if (!user || !user.pin_hash || !pinMatches) {
    await recordAttempt(admin, organizationId, phone, false);
    return json({ ok: false, error: "invalid_credentials" }, 401);
  }

  // --- (c) Success. Reset the counter, bridge into a real Auth session. ---
  await recordAttempt(admin, organizationId, phone, true);

  try {
    const authUserId = await ensureAuthUser(admin, user);
    const anon = createAnonClient();
    const session = await mintSession(admin, anon, syntheticEmail(user.id));

    return json({
      ok: true,
      access_token: session.accessToken,
      refresh_token: session.refreshToken,
      expires_in: session.expiresIn,
      token_type: session.tokenType,
      name: user.name,
      role: user.role,
      organization_id: user.organization_id,
      location_id: user.location_id,
    });
  } catch (err) {
    // The PIN was correct — this is a provisioning failure, not a credentials
    // one. Distinct error code so the frontend does not tell a correctly-
    // authenticated staff member their PIN was wrong.
    console.error(`[${TAG}] auth provisioning failed for user ${user.id}:`, err);
    return json({ ok: false, error: "auth_provisioning_failed" }, 500);
  }
}

// ---------------------------------------------------------------------------
// Entrypoint
// ---------------------------------------------------------------------------

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") {
    return json({ error: "method_not_allowed" }, 405);
  }

  try {
    return await handleLogin(req);
  } catch (err) {
    console.error(`[${TAG}] unhandled failure:`, err);
    return json({
      ok: false,
      error: "internal_error",
      detail: err instanceof Error ? err.message : String(err),
    }, 500);
  }
});
