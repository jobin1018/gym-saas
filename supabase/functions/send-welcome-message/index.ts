// send-welcome-message — one welcome WhatsApp to a brand-new member.
//
// POST { member_id }
// Authorization: Bearer <the owner's / front_desk's own staff-login token>
//
// ============================================================================
// WHY A SEPARATE FUNCTION
// ============================================================================
// Member creation stays a direct authenticated write from the frontend (RLS
// scopes it to the caller's org). This function is called AFTER that write
// succeeds, and only does the messaging side — same write-logic / external-API
// separation as renewal-scan -> send-renewal-reminder. It never creates a
// member.
//
// ============================================================================
// TRUST MODEL — same as staff-manage / staff-pin-reset
// ============================================================================
// verify_jwt = true (config.toml) stops keyless traffic at the gateway; this
// function then RE-validates the bearer via admin.auth.getUser() and reads the
// caller's role / org / active FROM public.users. The caller must be an active
// owner or front_desk, and the member must be in the caller's own org.
//
// ============================================================================
// BUSINESS-INITIATED => TEMPLATE REQUIRED
// ============================================================================
// A brand-new member has never messaged the bot, so there is no open 24h
// service window and Meta REJECTS a free-form send. This message must go as
// an APPROVED template — currently registered as "member_welcome" (the
// earlier "welcome_message" name attempted here was never the approved one;
// corrected to match the WABA).
//
// The BEGIN/END TEMPORARY SEND MODE block below is a deliberate safety gate,
// not dead code: it stays in place so a staging/prod environment that hasn't
// yet set WELCOME_TEMPLATE_APPROVED=true degrades to a queued-only audit row
// (no Meta call) instead of a bounced send. Once member_welcome's approval is
// confirmed live on a given environment's WABA, set the project secret
// there: `supabase secrets set WELCOME_TEMPLATE_APPROVED=true` — no code
// change needed, the real templated send via ../_shared/whatsapp.ts is
// already wired up below.
//
// This mirrors razorpay-webhook's TODO(meta) discipline for payment_failed /
// pt_payment_confirmation, but fences the send explicitly because — unlike
// those replies, which sit inside a service window — a premature real send
// here would just bounce.
// ============================================================================

import "@supabase/functions-js/edge-runtime.d.ts";
import { createAdminClient, type SupabaseClient } from "../_shared/supabase.ts";
import { corsJson as json, corsPreflightResponse } from "../_shared/cors.ts";
import { sendWhatsAppMessage, type TemplateSpec } from "../_shared/whatsapp.ts";
import { orgStatusIsActive } from "../_shared/org-status.ts";

const TAG = "send-welcome-message";
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

const TEMPLATE_NAME = "member_welcome";
const TEMPLATE_LANGUAGE = "en_GB"; // Meta's code for "English (UK)", not "en"
// NOTE: language code and single-{{1}}-param body carried over unverified
// from the old "welcome_message" attempt — confirm both still match
// member_welcome's actual approved template before relying on a real send.

function welcomeTemplateApproved(): boolean {
  return (Deno.env.get("WELCOME_TEMPLATE_APPROVED") ?? "").trim().toLowerCase() === "true";
}

function welcomeText(orgName: string): string {
  return `Welcome to ${orgName}! Your membership is now active. ` +
    `Reply IN when you arrive to check in, or PAY anytime to renew.`;
}

interface CallerUser {
  id: string;
  organization_id: string;
  role: string;
  active: boolean;
}

async function resolveCaller(
  admin: SupabaseClient,
  req: Request,
): Promise<CallerUser | null> {
  const bearer = (req.headers.get("authorization") ?? "").replace(/^bearer\s+/i, "").trim();
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

async function handle(req: Request): Promise<Response> {
  let body: any;
  try {
    body = await req.json();
  } catch {
    return json({ ok: false, error: "invalid_json_body" }, 400);
  }

  const memberId = typeof body?.member_id === "string" ? body.member_id.trim() : "";
  if (!memberId || !UUID_RE.test(memberId)) {
    return json({ ok: false, error: "member_id_malformed" }, 400);
  }

  const admin = createAdminClient();

  const caller = await resolveCaller(admin, req);
  if (!caller) return json({ ok: false, error: "unauthenticated" }, 401);
  if (!caller.active) return json({ ok: false, error: "caller_deactivated" }, 403);
  if (caller.role !== "owner" && caller.role !== "front_desk") {
    return json({ ok: false, error: "not_authorized", detail: "owner or front_desk only" }, 403);
  }

  // Member must exist and be in the caller's own org.
  const { data: member, error: memErr } = await admin
    .from("members")
    .select("id, organization_id, name, phone, whatsapp_opt_in")
    .eq("id", memberId)
    .maybeSingle();
  if (memErr) throw memErr;
  if (!member || (member as any).organization_id !== caller.organization_id) {
    return json({ ok: false, error: "member_not_found" }, 404);
  }

  const { data: org, error: orgErr } = await admin
    .from("organizations")
    .select("name, status")
    .eq("id", caller.organization_id)
    .maybeSingle();
  if (orgErr) throw orgErr;
  if (!org) return json({ ok: false, error: "organization_not_found" }, 404);

  // --- Skip cleanly (200, not an error) on either guard. ---
  if (!(member as any).whatsapp_opt_in) {
    console.log(`[${TAG}] member ${memberId} has whatsapp_opt_in=false — skipping.`);
    return json({ ok: true, skipped: "opted_out" });
  }
  if (!orgStatusIsActive((org as any).status)) {
    console.log(`[${TAG}] org ${caller.organization_id} status=${(org as any).status} — skipping welcome.`);
    return json({ ok: true, skipped: "org_suspended" });
  }

  // Idempotency: never send a member two welcomes.
  const { count: priorCount, error: priorErr } = await admin
    .from("whatsapp_messages")
    .select("id", { count: "exact", head: true })
    .eq("member_id", memberId)
    .eq("template_name", TEMPLATE_NAME);
  if (priorErr) throw priorErr;
  if ((priorCount ?? 0) > 0) {
    return json({ ok: true, skipped: "already_sent" });
  }

  const text = welcomeText((org as any).name);

  // ===== BEGIN TEMPORARY SEND MODE — gated on WELCOME_TEMPLATE_APPROVED =====
  if (!welcomeTemplateApproved()) {
    console.log(
      `[${TAG}] WELCOME_TEMPLATE_APPROVED not set on this environment — ` +
        `writing audit row only for "${TEMPLATE_NAME}", no Meta call. to=${(member as any).phone}`,
    );
    const { data: row, error: logErr } = await admin
      .from("whatsapp_messages")
      .insert({
        organization_id: caller.organization_id,
        member_id: memberId,
        direction: "outbound",
        template_name: TEMPLATE_NAME,
        body_preview: text,
        wa_message_id: null,
        status: "queued",
      })
      .select("id")
      .single();
    if (logErr) {
      console.error(`[${TAG}] failed to write audit row:`, logErr);
      return json({ ok: false, error: "log_failed" }, 500);
    }
    return json({
      ok: true,
      simulated: true,
      reason: "template_pending_approval",
      message_id: row.id,
    });
  }
  // ===== END TEMPORARY SEND MODE ===========================================

  const template: TemplateSpec = {
    name: TEMPLATE_NAME,
    language: TEMPLATE_LANGUAGE,
    bodyParams: [(org as any).name],
  };
  const result = await sendWhatsAppMessage(admin, (member as any).phone, text, {
    tag: TAG,
    memberId,
    organizationId: caller.organization_id,
    templateName: TEMPLATE_NAME,
  }, template);

  return json({
    ok: true,
    message_id: result.messageId,
    status: result.status,
    logged: result.logged,
  });
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
