// Platform-subscription status — the one list of organization statuses that
// count as "live". Anything not in here (today: only 'suspended') is frozen:
// no login, no WhatsApp, no scheduled sends, RLS returns zero rows.
//
// This mirrors, in the Edge-Function layer, what public.current_org_active()
// enforces at the database layer (20260902090000_org_status_enforcement.sql).
// Keep the two in step.

export const ACTIVE_ORG_STATUSES = ["trial", "active"] as const;

export type OrgStatus = "trial" | "active" | "suspended";

/** True unless the org is suspended (or missing). Pass the row's `status`. */
export function orgStatusIsActive(status: string | null | undefined): boolean {
  return status === "trial" || status === "active";
}
