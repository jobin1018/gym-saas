// Inbound-message loop protection for whatsapp-webhook.
//
// Incident 2026-10-22: JioCare's auto-responder ("For any support related
// queries, please chat with JioCare. (7000770007)") replied to our bot, our bot
// replied to it, and the two ping-ponged ~30 times at ~9s intervals.
//
// Three independent guards, all "stay silent but still log":
//   (a) per-phone reply cap  — see REPLY_CAP / REPLY_WINDOW_MINUTES
//   (b) known auto-responder text
//   (c) our own number, and Meta system senders

export type SuppressReason =
  | "auto_responder"
  | "own_number"
  | "system_sender"
  | "rate_limited";

/** Never send a phone more than this many replies... */
export const REPLY_CAP = Number(Deno.env.get("WA_REPLY_CAP") ?? 5);
/**
 * Known staff (owner/coach/front_desk) get a higher cap: a person working
 * through REVENUE / TODAY / OVERDUE / ... in one sitting is normal, but the
 * number must still be bounded so a staff phone behind an auto-responder
 * can't loop forever either.
 */
export const REPLY_CAP_STAFF = Number(Deno.env.get("WA_REPLY_CAP_STAFF") ?? 30);
/** ...inside this sliding window. */
export const REPLY_WINDOW_MINUTES = Number(Deno.env.get("WA_REPLY_WINDOW_MINUTES") ?? 10);

// Phrases only — never short tokens. Members legitimately send "IN", "PAY",
// "SWITCH", "Hi", "thanks", so every pattern must be a phrase that only a
// machine (or a deliberately templated business reply) produces.
const AUTO_RESPONDER_PATTERNS: RegExp[] = [
  /\bchat with jio\s?care\b/i,
  /\bjio\s?care\b.*\b7000770007\b/i,
  /\bfor any support related queries\b/i,
  /\bthis is an? (auto|automated)[- ]?(reply|response|message|responder)\b/i,
  /\bauto[- ]?(reply|responder|response)\b/i,
  /\bthis (number|chat|account) is not monitored\b/i,
  /\bdo not reply to this (message|number|chat)\b/i,
  /\bplease do not reply\b/i,
  /\bthank you for (contacting|reaching out to|messaging) us\b.*\b(will|shall) (get back|respond|reply)\b/i,
  /\bwe are (currently )?(away|closed|unavailable)\b.*\b(will|shall) (get back|respond|reply)\b/i,
  /\bout of (the )?office\b/i,
];

export function isAutoResponderText(body: string): boolean {
  if (!body) return false;
  return AUTO_RESPONDER_PATTERNS.some((re) => re.test(body));
}

/** Digits only — identical to normalizePhone() in index.ts. */
function digits(raw: string | null | undefined): string {
  return (raw ?? "").replace(/\D/g, "");
}

/**
 * Cheap, DB-free checks (b) and (c). Returns the reason to stay silent, or
 * null. The rate cap (a) needs the database and lives in index.ts.
 *
 * `ownNumbers`: our own WhatsApp number(s), digits only — taken from the
 * payload's metadata.display_phone_number plus the optional OWN_WHATSAPP_NUMBER
 * env (comma-separated).
 */
export function classifyInbound(input: {
  phone: string;
  body: string;
  type: string | null;
  ownNumbers: string[];
}): SuppressReason | null {
  const { phone, body, type, ownNumbers } = input;

  // (c) Meta system senders: `system` message type (number-change notices,
  // identity changes), or a "from" that cannot be a subscriber phone (E.164 is
  // 7-15 digits; Meta service ids and short codes fall outside it).
  if (type === "system" || phone.length < 7 || phone.length > 15) return "system_sender";

  // (c) Our own number echoing back at us.
  if (ownNumbers.some((n) => n !== "" && n === phone)) return "own_number";

  // (b) Known auto-responder text.
  if (isAutoResponderText(body)) return "auto_responder";

  return null;
}

/** Our own number(s), normalised, from the payload metadata + env. */
export function ownNumbersFor(payloadOwn: string | null): string[] {
  const fromEnv = (Deno.env.get("OWN_WHATSAPP_NUMBER") ?? "").split(",").map(digits);
  return [digits(payloadOwn), ...fromEnv].filter((n) => n !== "");
}
