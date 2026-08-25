// Shared CORS handling for Edge Functions actually called directly from a
// browser — today that's staff-login and staff-lookup-by-phone only (see
// each function's own header comment for why). Every other function in this
// project is invoked server-to-server (a provider webhook, pg_cron, or
// another function) or via curl during testing, none of which are subject to
// CORS at all — CORS is a BROWSER enforcement mechanism, not a server one.
//
// ============================================================================
// WHY THIS WASN'T NEEDED UNTIL NOW — AND WHY "IT WORKED LOCALLY" PROVED NOTHING
// ============================================================================
// Local dev (`supabase start`) fronts every function with a bundled Kong
// gateway that answers OPTIONS preflight automatically, with permissive CORS
// headers, for every /functions/v1/* route — confirmed by curling OPTIONS
// against a function with zero CORS code and getting a clean 200 back with
// Access-Control-Allow-* headers already attached, before the function's own
// code ever ran. That is a local-dev convenience of the CLI's Kong template,
// not something the deployed product provides: Supabase's actual hosted Edge
// Functions network has no equivalent, and its own CORS documentation is
// explicit that a function must handle OPTIONS itself. So a function that
// "worked" when exercised against local Kong was never actually proven to
// handle CORS correctly — the gap was just invisible until something called
// it against a real deployment from a real browser.
// ============================================================================

/**
 * Access-Control-Allow-Origin is "*" deliberately, for now — this project is
 * pre-production. TODO(cors): restrict this to the real frontend origin(s)
 * (e.g. https://<app>.vercel.app) before any real production use. Left as a
 * wildcard rather than guessed at, since picking the real value is a
 * deliberate decision for whoever owns the frontend deployment, not
 * something to decide silently here.
 *
 * Headers list matches supabase-js's own default client behaviour (every
 * request — including functions.invoke() — carries `apikey` and
 * `x-client-info` alongside `authorization`/`content-type`), same set
 * Supabase's own Edge Functions CORS guide documents. If a browser's
 * Network tab shows a preflight rejected over a header not in this list,
 * that's the Access-Control-Request-Headers value on the actual OPTIONS
 * request — add whatever it names here.
 */
export const CORS_HEADERS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, content-type, apikey, x-client-info",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

/** The OPTIONS preflight response — must return before any other logic runs. */
export function corsPreflightResponse(): Response {
  return new Response("ok", { status: 200, headers: CORS_HEADERS });
}

/**
 * JSON response with CORS headers attached — browsers check the CORS headers
 * on the ACTUAL response too, not just the preflight. Use this instead of a
 * bare `new Response(JSON.stringify(...))` for every response a browser-
 * facing function returns, success or error alike (a browser needs the
 * headers on error responses to even let calling code see the error body).
 */
export function corsJson(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json", ...CORS_HEADERS },
  });
}
