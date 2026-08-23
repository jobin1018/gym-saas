# gym-saas

Multi-tenant gym management backend on Supabase. WhatsApp-first: members check in,
renew and pay over WhatsApp; owners get a daily summary on the same channel.

**Status:** Phase 1 backend complete — six Edge Functions, 392 passing assertions.
No frontend in this repo (see [Frontend](#frontend)).

---

## ⚠️ Before this ever leaves localhost

Two migrations **disable multi-tenant isolation** so the UI could be wired up
before auth exists. Any holder of the public anon key can currently read every
tenant's members, payments and message history, and create members in any
organization.

| migration | what it opens |
|---|---|
| `20260823160000_LOCAL_DEV_ONLY_permissive_read_policies.sql` | `SELECT` for `anon` on 8 tables |
| `20260823170000_LOCAL_DEV_ONLY_permissive_write_policies.sql` | `INSERT` for `anon` on `members`, `memberships` |

Each file carries its own rollback SQL. Run both, delete both files, then verify:

```sql
select * from pg_policies
 where schemaname = 'public' and policyname like 'local_dev_%';
-- MUST return zero rows on any non-local database
```

`public.users` (holds `pin_hash`) and `public.webhook_events` (raw provider
payloads) are deliberately excluded from both.

---

## Architecture

Six functions. Two receive webhooks, three run on a schedule, one is called by
another function.

| function | trigger | what it does |
|---|---|---|
| `whatsapp-webhook` | Meta webhook | Inbound messages: self check-in, tenant disambiguation, renewal replies |
| `razorpay-webhook` | Razorpay webhook | Reconciles payments, extends the paid period, flips membership back to `active` |
| `mark-overdue` | cron 06:45 IST | `active` → `past_due` for lapsed memberships |
| `renewal-scan` | cron 07:00 IST | Finds memberships due, fans out to `send-renewal-reminder` |
| `send-renewal-reminder` | called by `renewal-scan` | Creates the Razorpay payment link + `payments` row, sends the reminder |
| `daily-owner-brief` | cron 07:00 IST | One WhatsApp summary per gym owner |

**The renewal chain**, which is the heart of the system:

```
mark-overdue        06:45  writes memberships.status
      ↓
renewal-scan        07:00  selects due memberships (7 and 3 days out)
      ↓                     one call per membership
send-renewal-reminder      creates a REAL Razorpay payment link
      ↓                     writes payments{status:pending, razorpay_link_id, provider_payment_id:NULL}
   [member pays]
      ↓
razorpay-webhook           matches that row, marks it success,
                           extends current_period_end, sets status:'active'
```

Ordering matters: `mark-overdue` runs 15 minutes early because the other two
*read* the status column it maintains.

### What is real and what is simulated

- **Real:** the Razorpay Payment Links API (test mode), both webhook HMAC
  signature verifications, and every number in every message.
- **Simulated:** outbound WhatsApp sending only. `_shared/whatsapp.ts`
  `console.log`s inside a `BEGIN/END SIMULATED SEND` fence and writes a real
  `whatsapp_messages` row with `status: 'queued'`. That row is a real audit log
  and doubles as the once-per-day guard.

Find the whole simulated surface:

```bash
rg 'BEGIN SIMULATED SEND' supabase/functions
rg 'TODO\((meta|razorpay)\)' supabase/functions
```

### Idempotency

Every function is safe to run twice — a scheduler that fires twice must not
double-charge or double-message anyone.

| guard | mechanism |
|---|---|
| Webhook replay | `webhook_events (source, event_id)` UNIQUE, claimed before any business logic |
| One payment per renewal period | `payments.idempotency_key` UNIQUE (`renewal-{membership}-{period_end}`) + a derived Razorpay `reference_id` |
| One reminder per member per day | `whatsapp_messages` lookback in the tenant's timezone |
| One brief per org per day | same, keyed on `organization_id` + `template_name` |
| Status transitions | `mark-overdue`'s UPDATE re-checks its own filters (compare-and-set) |

---

## Getting started

**Prerequisites:** Docker, the [Supabase CLI](https://supabase.com/docs/guides/cli),
`curl`, `openssl`. Razorpay **test mode** API keys.

```bash
# 1. Credentials
cp supabase/functions/.env.example supabase/functions/.env
#    fill in RAZORPAY_* and META_* — see the comments in that file

# 2. Start Postgres, PostgREST, the edge runtime, Studio
supabase start

# 3. Apply migrations + seed data
supabase db reset

# 4. Serve all functions (one terminal, leave running)
supabase functions serve --env-file supabase/functions/.env
```

Studio: <http://127.0.0.1:54323> · API: <http://127.0.0.1:54321>

### Calling a function

Every internal function requires the **service role key** — `verify_jwt = true`
alone is not enough, because it accepts the public anon key.

```bash
SRK=$(supabase status -o env | sed -n 's/^SERVICE_ROLE_KEY="\(.*\)"$/\1/p')

curl -s -X POST 'http://127.0.0.1:54321/functions/v1/renewal-scan' \
  -H "Authorization: Bearer $SRK" -H 'Content-Type: application/json' \
  -d '{"dry_run":true}'
```

`renewal-scan`, `daily-owner-brief` and `mark-overdue` all support
`{"dry_run": true}` — same query, same report, no writes and no external calls.
Use it before trusting any of them with real data.

### Scheduled jobs

The three cron migrations read `project_url` and `service_role_key` from Vault,
so the same migration works locally and deployed. `supabase db reset` wipes
Vault, so re-set them after every reset:

```sql
select vault.create_secret('http://kong:8000',   'project_url');       -- local
select vault.create_secret('<service-role-key>', 'service_role_key');
```

Locally the URL must be `http://kong:8000`, **not** `127.0.0.1:54321` — the cron
job runs inside the database container. Deployed it is
`https://<project-ref>.supabase.co`.

Fire one by hand without waiting for the morning:

```sql
select public.trigger_mark_overdue('{"dry_run":true}'::jsonb);
```

**pg_net is asynchronous**, so `cron.job_run_details` reports `succeeded` as soon
as the request is *queued* — a 401, a 404 or a 500 all look like success from
cron's side. The real answer lands in `net._http_response`. Each cron migration
has both queries in its footer.

---

## Testing

```bash
bash supabase/functions/run-all-tests.sh      # all six, one pass
bash supabase/functions/renewal-scan/test.sh  # or one at a time
```

| suite | assertions |
|---|---|
| `whatsapp-webhook` | 40 |
| `mark-overdue` | 55 |
| `daily-owner-brief` | 88 |
| `send-renewal-reminder` | 60 |
| `renewal-scan` | 82 |
| `razorpay-webhook` | 67 |
| **total** | **392** |

All six share one database and one seed, so run them together before trusting a
change — a suite that fails to restore its fixtures only shows up that way.

Two things to know:

- **`send-renewal-reminder` and `renewal-scan` create real Razorpay test-mode
  payment links** and print the URLs. Nothing is charged. Both refuse to run
  against an `rzp_live_` key. Running the full suite repeatedly in a short window
  can trip Razorpay's per-account rate limit; wait a minute and re-run.
- The webhook suites mock the *provider* by signing their own payloads with the
  real HMAC secret — the signature verification under test is genuine.

---

## Schema

`supabase/migrations/20260822041613_create_core_schema.sql`

```
organizations ──┬── locations ──┬── members ──┬── memberships ── membership_plans
                │               │             │        │
                ├── users       │             │        └── payments
                │  (owner /     │             │
                │   front_desk) │             ├── attendance
                │               │             └── whatsapp_messages
                └───────────────┴─────────────── webhook_events
```

Everything tenant-scoped carries `organization_id`. RLS is enabled on all nine
tenant tables — but see the warning at the top: the real policies are not wired
up yet.

**Seed data** (`supabase/seed.sql`) gives you two gyms, four members, four
memberships, three payment fixtures, and four staff logins (one owner + one
front desk per gym, `pin_hash` NULL). Test phone numbers and payment fixture ids
are documented in the file header.

---

## Frontend

There is none in this repo. `tools/smoke-test.html` is a disposable page that
proves the browser can reach real seeded data through `@supabase/supabase-js`:

```bash
python -m http.server 5173 --directory tools
# open http://127.0.0.1:5173/smoke-test.html, then the devtools console
```

Serve it over `http://` — a `file://` page has a null origin and CORS rejects it.
Delete it along with the two `LOCAL_DEV_ONLY` migrations.

Client setup for wherever your UI lives:

```ts
import { createClient } from '@supabase/supabase-js'

export const supabase = createClient(
  import.meta.env.VITE_SUPABASE_URL,      // http://127.0.0.1:54321
  import.meta.env.VITE_SUPABASE_ANON_KEY, // supabase status -o env | grep ANON_KEY
)
```

Reads work directly. Writes are limited to `members` and `memberships`; anything
touching money or messages goes through an Edge Function on purpose, because
those invariants are procedural and a direct write would route around them.

---

## Open items

Known and deliberate, in rough priority order.

1. **Auth is not built.** RLS policies read `app.current_org_id`, which nothing
   sets. Real PIN login needs: a `staff-login` Edge Function, a **slow KDF** for
   `pin_hash` (a 4-digit PIN under SHA-256 is brute-forceable in milliseconds —
   `_shared/crypto.ts` has no KDF today) plus login rate limiting, JWT claims
   carrying `org_id`, policies rewritten to `auth.jwt() ->> 'org_id'`, grants for
   `authenticated`, and token expiry/refresh/revocation. `users.auth_user_id`
   already exists unused, and `[auth.hook.custom_access_token]` is already
   commented out in `config.toml` — the schema was designed to bridge into
   Supabase Auth rather than hand-roll it.
2. **The two `LOCAL_DEV_ONLY` migrations must be rolled back and deleted.**
3. **Real WhatsApp sending.** Replace the fenced block in `_shared/whatsapp.ts`,
   register `renewal_reminder` and `daily_owner_brief` as approved Meta
   templates (business-initiated messages fall outside the 24h window), consume
   `value.statuses` in `whatsapp-webhook` to advance `whatsapp_messages.status`,
   then set `WHATSAPP_DELIVERY_TRACKING=live`.
4. **Verify Razorpay copies link `notes` onto the payment.** `razorpay-webhook`'s
   tier-3/4 fallback lookup depends on it. Confirmed stored on the link via the
   API; the copy-to-payment step needs one manual test payment. Low risk — those
   tiers only ever *add* matches.
5. **`organizations.owner_phone` and `users.role='owner'` are not linked.** The
   seed keeps them equal; nothing enforces it. Decide which is authoritative.
6. **Two duplicated copies of the WhatsApp send helper** remain inline in
   `whatsapp-webhook` and `razorpay-webhook`, predating `_shared/whatsapp.ts`.
   Mechanical to migrate.
7. **`billing_interval` is CHECK-constrained to `'monthly'`.** Quarterly/annual
   plans need `addOneMonth()` in `razorpay-webhook` generalised.
