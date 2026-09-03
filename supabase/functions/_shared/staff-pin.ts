// Shared staff-PIN-reset logic: hash server-side, write, clear the lockout
// window. Extracted from staff-pin-reset so a SECOND sanctioned way to reset
// a PIN — whatsapp-webhook's RESET PIN command — does it the EXACT same way
// rather than via a parallel, possibly-weaker path. Same reuse discipline as
// ../_shared/staff-session.ts (mintSession et al., extracted for
// validate-magic-link to share with staff-login).

import bcrypt from "bcryptjs";
import type { SupabaseClient } from "./supabase.ts";

export const PIN_RE = /^\d{4,8}$/;
const BCRYPT_COST = 12;

export interface PinResetTarget {
  id: string;
  organization_id: string;
  phone: string;
}

/**
 * Hash newPin server-side (never trust a hash from the caller — only ever
 * the plaintext-input-to-be-hashed) and write it to the target user, scoped
 * to callerOrgId in the WHERE as defence in depth on top of the caller
 * already having verified target.organization_id matches. Also clears any
 * login_attempts lockout for the target's phone, so the new PIN works
 * immediately rather than after the cooldown — PIN reset doubling as
 * lockout recovery, same behaviour staff-pin-reset has had since it shipped.
 */
export async function resetStaffPin(
  admin: SupabaseClient,
  callerOrgId: string,
  target: PinResetTarget,
  newPin: string,
  tag: string,
): Promise<void> {
  const pinHash = await bcrypt.hash(newPin, BCRYPT_COST);

  const { error: updateErr } = await admin
    .from("users")
    .update({ pin_hash: pinHash })
    .eq("id", target.id)
    .eq("organization_id", callerOrgId);
  if (updateErr) throw updateErr;

  const { error: lockoutErr } = await admin
    .from("login_attempts")
    .delete()
    .eq("organization_id", callerOrgId)
    .eq("phone", target.phone);
  if (lockoutErr) {
    // The PIN is already reset; a stale lockout row just means the staffer
    // waits out the window. Loud log, not a failure.
    console.error(`[${tag}] pin reset for ${target.id} ok, but clearing login_attempts failed:`, lockoutErr);
  }
}
