// Shared HMAC helpers for webhook signature verification.
//
// Both inbound webhooks authenticate the same way — HMAC-SHA256 over the RAW
// request body, hex-encoded, compared in constant time:
//   whatsapp-webhook → X-Hub-Signature-256    (key: META_APP_SECRET)
//   razorpay-webhook → X-Razorpay-Signature   (key: RAZORPAY_WEBHOOK_SECRET)
//
// Only the header name and the secret differ, so the primitives live here.

/**
 * Hex-encoded HMAC-SHA256 of `body` keyed on `secret`.
 *
 * `body` must be the exact bytes the provider sent. Re-serializing a parsed
 * object will not reproduce them (key order, whitespace and unicode escaping
 * all differ) and the digest will never match — which is why both webhook
 * handlers read `req.text()` and parse manually rather than `req.json()`.
 */
export async function hmacSha256Hex(
  secret: string,
  body: string,
): Promise<string> {
  const encoder = new TextEncoder();
  const key = await crypto.subtle.importKey(
    "raw",
    encoder.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = await crypto.subtle.sign("HMAC", key, encoder.encode(body));

  return Array.from(new Uint8Array(signature))
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
}

/**
 * Hex-encoded SHA-256 of `input` — a plain digest, no key.
 *
 * Used by send-renewal-reminder to derive a Razorpay `reference_id` from its
 * payments.idempotency_key: the key itself ("renewal-<uuid>-<date>", 55 chars)
 * is longer than Razorpay's 40-character reference_id limit, and a hash keeps
 * the value deterministic — which is what makes the link recoverable by
 * reference_id after a crash.
 */
export async function sha256Hex(input: string): Promise<string> {
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(input),
  );

  return Array.from(new Uint8Array(digest))
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
}

/**
 * Compare two hex digests without leaking their contents through timing.
 *
 * A plain `===` short-circuits on the first differing character, so an attacker
 * can recover the expected digest byte by byte by measuring response latency.
 * This always walks the full string.
 */
export function timingSafeEqualHex(a: string, b: string): boolean {
  if (a.length !== b.length) return false;

  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);

  return diff === 0;
}
