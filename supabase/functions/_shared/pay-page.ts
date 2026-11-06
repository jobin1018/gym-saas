// Shared plumbing for the two PUBLIC pay-page functions (get-pay-page,
// claim-paid): token shape check, per-client rate limiting, client key.
// Both functions are verify_jwt = false and anonymous by design — the 128-bit
// token is the credential — so they are rate limited and reveal nothing about
// why a token failed beyond "not found".

import { type SupabaseClient } from "./supabase.ts";
import { sha256Hex } from "./crypto.ts";

export const TOKEN_RE = /^[0-9a-f]{32}$/;

/** Requests per client per window. Overridable for tests. */
export const RATE_LIMIT = Number(Deno.env.get("PAY_PAGE_RATE_LIMIT") ?? 30);
export const RATE_WINDOW_SECONDS = Number(Deno.env.get("PAY_PAGE_RATE_WINDOW_SECONDS") ?? 60);

/** Hash of scope + best-available client address; the raw IP is never stored. */
export async function clientBucket(req: Request, scope: string): Promise<string> {
  const ip = (req.headers.get("cf-connecting-ip") ??
    req.headers.get("x-forwarded-for")?.split(",")[0] ??
    req.headers.get("x-real-ip") ?? "unknown").trim();
  return `${scope}:${(await sha256Hex(ip)).slice(0, 32)}`;
}

/** True if the caller may proceed. Fails CLOSED if the limiter itself errors. */
export async function allowRequest(
  supabase: SupabaseClient,
  bucket: string,
): Promise<boolean> {
  const { data, error } = await supabase.rpc("pay_page_rate_check", {
    p_bucket: bucket,
    p_limit: RATE_LIMIT,
    p_window_seconds: RATE_WINDOW_SECONDS,
  });
  if (error) {
    console.error("[pay-page] rate limiter failed:", error);
    return false;
  }
  return data === true;
}

export async function readToken(req: Request): Promise<string | null> {
  let body: any;
  try {
    body = await req.json();
  } catch {
    return null;
  }
  const t = typeof body?.token === "string" ? body.token.trim().toLowerCase() : "";
  return TOKEN_RE.test(t) ? t : null;
}
