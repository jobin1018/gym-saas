// Shared staff-session bridge: auth.users provisioning + real session minting
// for a phone-only public.users staffer.
//
// Extracted verbatim from staff-login (its 20260824140000-era helpers) so a
// SECOND sanctioned way to establish a staff session — validate-magic-link,
// for coaches with no laptop — mints sessions the EXACT same way rather than
// via a parallel, possibly-weaker path. staff-login imports these too; its
// behaviour is unchanged.

import type { SupabaseClient } from "./supabase.ts";

/** A minimal public.users shape — the only fields the bridge touches. */
export interface StaffSessionUser {
  id: string;
  auth_user_id: string | null;
  name: string;
  role: string;
}

/**
 * The non-deliverable email that bridges a phone-only staff user into Supabase
 * Auth, which is email-centric at the Admin API surface we need
 * (`generateLink({type:'magiclink'})`). `.invalid` is the RFC 2606 reserved
 * TLD — never emailed anywhere; we only ever redeem the link token directly.
 */
export function syntheticEmail(userId: string): string {
  return `${userId}@staff.internal.invalid`;
}

/**
 * Returns the user's auth_user_id, creating the bridging auth.users row (and
 * writing it back) on first use. Compare-and-set on the write: if a concurrent
 * request already won, this returns THEIR auth_user_id and leaves the
 * auth.users row just created here as a harmless orphan. Never two
 * auth_user_id values in play for one users row.
 */
export async function ensureAuthUser(
  admin: SupabaseClient,
  user: StaffSessionUser,
  tag: string,
): Promise<string> {
  if (user.auth_user_id) return user.auth_user_id;

  const email = syntheticEmail(user.id);

  const { data: created, error: createErr } = await admin.auth.admin.createUser({
    email,
    email_confirm: true,
    user_metadata: { staff_user_id: user.id, name: user.name, role: user.role },
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

  if (updated) return newAuthUserId; // won the race

  const { data: winner, error: reReadErr } = await admin
    .from("users")
    .select("auth_user_id")
    .eq("id", user.id)
    .single();

  if (reReadErr || !winner?.auth_user_id) {
    throw new Error(`[${tag}] lost the auth_user_id race but could not re-read the winner`);
  }

  return winner.auth_user_id;
}

/**
 * Keeps auth.users.user_metadata.name/role in sync with public.users. Never
 * throws — the caller has already authorised the session by the time this
 * runs, so a metadata-sync failure must not cost the user their session.
 */
export async function syncUserMetadata(
  admin: SupabaseClient,
  authUserId: string,
  user: StaffSessionUser,
  tag: string,
): Promise<void> {
  const { data, error } = await admin.auth.admin.getUserById(authUserId);

  if (error || !data?.user) {
    console.error(`[${tag}] could not read auth.users ${authUserId} to sync metadata:`, error);
    return;
  }

  const current = data.user.user_metadata ?? {};
  if (current.name === user.name && current.role === user.role) return;

  const { error: updateErr } = await admin.auth.admin.updateUserById(authUserId, {
    user_metadata: { ...current, name: user.name, role: user.role },
  });

  if (updateErr) {
    console.error(`[${tag}] failed to sync user_metadata for ${authUserId}:`, updateErr);
  }
}

export interface MintedSession {
  accessToken: string;
  refreshToken: string;
  expiresIn: number;
  tokenType: string;
}

/**
 * Mint a real session for `email`'s auth user via the Admin API, no password
 * flow. admin.generateLink({type:'magiclink'}) creates the redeemable token
 * server-side (no email is sent); the anon-keyed client redeems it via
 * verifyOtp() — /verify is a public GoTrue endpoint gated on `apikey` alone,
 * and keeping "mint" (service_role) and "redeem" (anon) as distinct clients
 * mirrors how the GoTrue REST API itself separates /admin/generate_link from
 * /verify.
 */
export async function mintSession(
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
