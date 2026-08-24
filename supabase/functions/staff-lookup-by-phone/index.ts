// staff-lookup-by-phone — resolve which org(s) a phone belongs to, pre-login.
//
// POST { phone }
//
// Runs BEFORE staff-login, not instead of it. staff-login's contract
// ({ organization_id, phone, pin }) is unchanged — this function exists so
// the frontend never needs a hardcoded, per-deployment gym/org list to get
// an organization_id in the first place. Same shape of problem
// member_active_context already solves for inbound WhatsApp (see
// ../whatsapp-webhook/index.ts's resolvePhone()): a phone number alone is
// ambiguous across tenants, because users has UNIQUE(organization_id, phone),
// not UNIQUE(phone) — the same phone CAN legitimately be a staff member at
// more than one gym.
//
// ============================================================================
// WHY A VIEW, NOT A DIRECT users QUERY
// ============================================================================
// This is the one query in the codebase that has to search users ACROSS every
// organization with no org_id to scope by first — exactly the shape of query
// that must never come within reach of pin_hash. public.staff_lookup_
// directory (see 20260824150000_create_staff_lookup_directory.sql) hard-codes
// that exclusion at the schema level rather than trusting this function to
// remember to .select() only safe columns.
//
// ============================================================================
// NO RATE LIMITING HERE — ON PURPOSE
// ============================================================================
// Rate limiting belongs on the PIN attempt, which is the actual credential
// check — staff-login already does that (login_attempts + the lockout RPCs).
// This function only ever answers "which org(s) is this phone at", the same
// information a phone number's own visible existence already implies to
// anyone who knows it; it does not verify anything secret, so throttling it
// separately would add complexity without closing a real gap. A basic format
// sanity check still guards against obviously garbage input reaching the DB.
// ============================================================================

import "@supabase/functions-js/edge-runtime.d.ts";
import { createAdminClient } from "../_shared/supabase.ts";

const TAG = "staff-lookup-by-phone";

// Digits only, loosely E.164-shaped (7-15 digits, ITU E.164's own bound) —
// a sanity check against garbage input, not full phone validation. Mirrors
// the normalization whatsapp-webhook's normalizePhone() does (strip
// non-digits) rather than importing it: one line, kept local on purpose, same
// deliberate-duplication call already made between whatsapp-webhook and
// razorpay-webhook's own send-helper copies (see ../_shared/whatsapp.ts's
// "NOTE ON DUPLICATION").
function normalizePhone(raw: string): string {
  return raw.replace(/\D/g, "");
}

const PHONE_RE = /^\d{7,15}$/;

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

interface Match {
  organization_id: string;
  organization_name: string;
  name: string;
  role: string;
}

async function handleLookup(req: Request): Promise<Response> {
  let body: any;
  try {
    body = await req.json();
  } catch {
    return json({ ok: false, error: "invalid_json_body" }, 400);
  }

  const rawPhone = typeof body?.phone === "string" ? body.phone.trim() : "";
  if (!rawPhone) {
    return json({ ok: false, error: "phone_required" }, 400);
  }

  const phone = normalizePhone(rawPhone);
  if (!PHONE_RE.test(phone)) {
    return json({ ok: false, error: "phone_malformed", detail: "expected 7-15 digits" }, 400);
  }

  const admin = createAdminClient();

  const { data, error } = await admin
    .from("staff_lookup_directory")
    .select("organization_id, organization_name, name, role")
    .eq("phone", phone);

  if (error) throw error;

  const matches = (data ?? []) as Match[];

  if (matches.length === 0) {
    // Deliberately generic — this is a pre-login lookup, not a credential
    // check, but there is still no reason to distinguish "never registered
    // anywhere" from any other non-match in the response shape.
    return json({ ok: false, error: "not_found" }, 404);
  }

  if (matches.length === 1) {
    const m = matches[0];
    return json({
      ok: true,
      organization_id: m.organization_id,
      organization_name: m.organization_name,
      name: m.name,
      role: m.role,
    });
  }

  return json({ ok: true, matches });
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") {
    return json({ error: "method_not_allowed" }, 405);
  }

  try {
    return await handleLookup(req);
  } catch (err) {
    console.error(`[${TAG}] unhandled failure:`, err);
    return json({
      ok: false,
      error: "internal_error",
      detail: err instanceof Error ? err.message : String(err),
    }, 500);
  }
});
