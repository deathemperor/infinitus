# CLIProxyAPI as an alternate backend — data-point mapping (2026-09-01)

Evaluated: router-for-me/CLIProxyAPI @ `81e1b53` (Go proxy pooling CLI
OAuth credentials behind an OpenAI-compatible endpoint) and its bundled
web UI CPAMC (Cli-Proxy-API-Management-Center @ `e0ee712`). The proxy
exposes a **Management API** (`/v0/management/...`, bearer management
key, localhost-only unless `remote-management.allow-remote`; routes 404
until a secret key is configured). This is the same isolation shape as
cswap — a subprocess boundary becomes an HTTP boundary; Infinitus
would never touch the proxy's internals or credential files.

Layer warning (same as the router-ecosystem note in TODO.md): the
proxy rotates per-request behind one endpoint, cswap swaps the
credential under the real client. Running both fights. A CLIProxyAPI
backend replaces the cswap engine for users who run the proxy, it does
not stack on it.

## Feature → API mapping

| Infinitus feature | CLIProxyAPI source | Status |
|---|---|---|
| Account roster, email, status, disabled | `GET /auth-files` (`id`, `email`, `status`, `disabled`, `unavailable`, counters) | ✅ (org name missing — fetch via `/api-call` → `api.anthropic.com/api/oauth/profile`, CPAMC does exactly this) |
| 5h/7d/per-model gauges (utilization + resetsAt) | `POST /api-call` per credential with `$TOKEN$` substitution → `api.anthropic.com/api/oauth/usage` (`five_hour`/`seven_day`/`weekly_scoped` incl. Fable) — CPAMC's own quota cards use this | ✅ client-side fan-out; nothing persisted proxy-side |
| Limit detection + recovery countdown | quota signals captured from `anthropic-ratelimit-unified-*` headers per credential and per model; `/auth-files` exposes `quota.signals`, `model_quotas`, auth-level `next_retry_after` | ⚠️ per-model recovery instants and scheduler `NextRecoverAt` are deliberately withheld (design comment in `auth_files.go` ~:448: cooldown ≠ observable state) |
| Disable/enable rotation (our ⏸) | `PATCH /auth-files/status {name, disabled}` | ✅ |
| Switch-to-account / next candidate | no pinned-active concept; routing strategy `round-robin`/`weighted-round-robin`/`fill-first` + per-credential `priority`/`weight` via `PATCH /auth-files/fields` | ⚠️ "switch to N" ≈ set N's priority to a top tier; "active" becomes "highest tier in rotation" |
| Add account (relogin) | `GET /anthropic-auth-url` → poll `GET /get-auth-status?state=` → `POST /oauth-callback` | ✅ |
| Usage-cost estimates | per-request records with `auth_index` + token counts via `GET /usage-queue` (destructive drain, 60s retention) or RESP `SUBSCRIBE usage` on the API port; `/auth-files` has success/failed + 20×10-min request buckets | ⚠️ no aggregated per-credential token totals endpoint; `/api-key-usage` is api-key auths only |
| Live events (switch/limit/recovery) | none for credential state — poll `/auth-files`; RESP stream is usage-records only | ⚠️ polling (we poll cswap on the same cadence anyway) |
| Live sessions / resume nudges | n/a — proxy clients are arbitrary; nudge mechanism stays ours and stays local | — |

## Verdict

**No PR is required to integrate.** A `CliProxyBackend` next to
`CswapCLI` can drive the whole popup: poll `/auth-files`, fan out
`/api-call` → `oauth/usage` for gauges, `PATCH /auth-files/status` for
rotation holds, OAuth-URL flow for adding accounts. Secrets posture
holds: the management key would live in the keychain, sent as a
header, never argv.

Upstream PR candidates (quality-of-life, in value order):

1. **Server-side quota endpoint** — `GET /auth-files/quota`: proxy
   (**posted 2026-09-03 as router-for-me/CLIProxyAPI#5434**, from the
   `deathemperor` fork, branch `feat/auth-files-quota`; app switches
   to it once merged). Proxy
   calls `oauth/usage` per Claude credential itself and returns
   normalized utilization/reset per window. Kills the N-call
   `/api-call` fan-out that every client (CPAMC included) reimplements.
   Natural home: new handler in
   `internal/api/handlers/management/`, reusing the `/api-call` token
   plumbing (`api_tools.go`).
2. **Aggregated per-credential usage totals** — a sink over
   `usage.Record` (already carries `AuthIndex` + token detail) with one
   GET handler; the destructive `/usage-queue` drain can't be shared by
   two collectors.
3. **Credential-state push channel** — add a `state` channel beside
   `usage`/`errors` in the RESP registry
   (`internal/api/redis_queue_protocol.go`), fed from availability
   transitions in `sdk/cliproxy/auth/conductor_cooldown.go`.

Not proposed: exposing per-model recovery instants (contends with an
explicit upstream design comment) and a pinned-active strategy
(priority tiers already emulate it).
