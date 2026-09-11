# 9Router as an engine (decolua/9router, 2026-09-03)

User: "add support for https://github.com/decolua/9router". Tracked as
the "9Router engine" issue. Landscape note from 2026-08-30 (TODO.md,
"Router ecosystem") parked it as the opposite layer to cswap — that
still holds for the `/v1` gateway; the engine seam (#8) makes the
management side a plain third `AccountEngine`.

## What it is
Node/Next.js gateway + dashboard on port 20128 (`npm i -g 9router`;
`9router --no-browser --skip-update --log` runs it headless). One
OpenAI-compatible endpoint, 40+ providers, per-request rotation across
a provider's connections in priority order (1 first; `reorderInTx`
renumbers on every priority write; ties → newer `updatedAt`), cooldown
fallback on quota/rate errors (`open-sse/services/accountFallback.js`),
own quota tracking. SQLite under `~/.9router/` — never read by us.

## Surface used (dashboard API, loopback)
| Need | Call | Notes |
|---|---|---|
| Roster | `GET /api/providers` → `{connections:[{id, provider, authType, name, email, priority, isActive, rateLimitedUntil?, lastError?, updatedAt}]}` | secrets stripped server-side; Claude OAuth rows carry NO email (name = "Account N") |
| Gauges | `GET /api/usage/{id}` → `{plan, extraUsage, quotas:{"session (5h)":{used,resetAt,…}, "weekly (7d)":…, "weekly <model> (7d)":…}}` or `{message}` | `used` = % used; `extra_usage` passed through verbatim; 9Router caches + 429-cools the Anthropic call itself |
| Switch | `PUT /api/providers/{id} {"priority":0}` | 0 sorts ahead of the renumbered 1..n |
| Hold | `PUT … {"isActive":false}` | 9Router skips inactive rows |
| Remove | `DELETE /api/providers/{id}` | |
| Auth | `POST /api/auth/login {"password"}` → `auth_token` cookie (24h JWT) | guard: CLI token OR (loopback AND cookie / `requireLogin=false`); we log in only after a 401 |
| Probe | `GET /api/health` (public) + providers count | |

Verified live 2026-09-03 against 0.5.65 with two Claude connections:
roster, 5h/7d with countdowns, switch (row moved to #1), restore, hold,
unhold.

## Decisions
- Rotation policy is 9Router's (priority order + cooldowns); the app
  sets priority / hold only. No star: priorities are a strict order,
  not tiers, so "prefer" has no honest mapping.
- OAuth add stays in the 9Router dashboard (`/api/oauth/claude/*` is
  a browser flow; the pane has an "Open dashboard" button).
- No cost report yet (9Router has `usage.json`/request logs; a later
  cut can read `GET /api/usage/...` aggregates if worth it).
- Identity: no email → rows show the connection name; cross-engine
  usage dedupe by email can't apply to these rows.
- Gateway side untouched: Claude Code keeps its own login unless the
  user sets `ANTHROPIC_BASE_URL`; then cswap and 9Router fight (Engines
  pane note). Detecting that env and showing "routed via 9Router" is a
  possible follow-up.
