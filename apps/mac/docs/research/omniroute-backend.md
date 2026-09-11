# OmniRoute as an engine (diegosouzapw/OmniRoute, 2026-09-03)

User: "OmniRoute as a fourth engine — same shape as 9Router". Read from
the repository only (no instance run yet); every row below is from the
source at HEAD on 2026-09-03 and is marked where a live check is still
owed.

## What it is
OmniRoute began as a fork of 9Router plus a TypeScript port of
CLIProxyAPI, and has grown into a much larger gateway (355 providers,
combos, MCP server, guardrails, cloud sync). For us only the management
side matters, and that side is still 9Router's: Next.js dashboard on
port 20128 (`localhost:20128` throughout the README), `/api/providers`
connections in priority order, per-connection quota reads, dashboard
password auth. It stores state in its own SQLite — never read by us.

## Surface used (dashboard API, loopback)
| Need | Call | Notes (vs 9Router) |
|---|---|---|
| Roster | `GET /api/providers[?provider=&limit=&offset=]` → `{connections:[…], total}` | paginated (9Router's isn't); secrets masked/stripped server-side; Codex rows can project a *pool* of child accounts with `quota.windows["5h"/"7d"].usedPercentage` |
| Gauges | `GET /api/usage/{connectionId}` → `usage` object with `plan` and `quotas:{<window>: {…, resetAt}}` | the same `fetchAndPersistProviderLimits` cache the dashboard's quota page uses; quota keys are provider-normalized (`normalizeUsageQuotasForProvider`) — **verify live** that Claude rows still use `session (5h)` / `weekly (7d)` / `weekly <model> (7d)` with `used` as a percentage |
| Switch | `PUT /api/providers/{id} {"priority":0}` | `PATCH` accepted too (delegates to PUT); renumbering semantics **verify live** |
| Hold | `PUT … {"isActive":false}` | same |
| Remove | `DELETE /api/providers/{id}` | same; also cleans the connection's model rows |
| Auth | `POST /api/auth/login {"password"}` → `{success:true}` + `auth_token` cookie | cookie is a **30-day** JWT (9Router: 24 h); refused when OIDC is active; `requireLogin === false` skips auth; a fresh install with no password is open on loopback only; management routes also accept a local CLI machine token |
| Probe | `GET /api/health` → `{status:"ok", timestamp}` (public, nothing else) | `GET /api/auth/status` for "is a password set" |

Also present but not needed: `GET /api/providers/{id}/claude-auth/export`
and `…/apply-local` (moves Claude credentials between OmniRoute and the
local Claude Code login — the opposite direction from cswap's own
switching; leave alone), `/api/quota/*` (plans, pools, groups: OmniRoute's
own quota-share scheduling), `/api/usage/analytics` and call logs (a
later cost-report source).

## Decisions (proposed)
- Same seam as 9Router (`AccountEngine` → `EngineFleet`), same
  capabilities (switch, hold, remove; no star, no OAuth add, no cost
  report). Rotation policy stays OmniRoute's.
- Implement as the 9Router engine with a second identity, not a copy:
  `NineRouterEngine` keeps its one HTTP client and mapping;
  `engineID`/display name/default URL/keychain service become per-instance
  values ("omniroute", same port 20128 by default — the two can't run
  side by side on the default port, so the pane's base-URL field is the
  disambiguator). The roster call passes `limit=500` (or pages on
  `total`) so a paginated reply isn't truncated.
- Identity: as with 9Router, Claude OAuth rows carry no email; rows show
  the connection name.
- Before any code: run an instance (`npx omniroute` or Docker) with one
  Claude connection and confirm the two **verify live** rows above; the
  quota-key names are the one thing that could break the mapping.
