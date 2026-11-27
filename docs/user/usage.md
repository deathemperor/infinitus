# Usage and limits

Track token usage, cache hit rates, estimated API-equivalent costs, and pooled subscription quotas across all connected environments.

- **Open Usage**: Click **Usage** in the sidebar, press `mod+u` (web/desktop outside terminals), or pick **Usage** on mobile.
- **Quick shortcuts** (web/desktop on Usage): `C` (Cost), `T` (Tokens), `L` (Limits), `mod+Shift+1/2/3/4` (24h / 7d / 30d / 90d), `Esc` (back).

## Understand your usage

Usage aggregates history across Codex, Claude Code, Grok Build, OpenCode, Antigravity, Pi, Muse Code, and Cursor from your selected environments. Estimates reflect API-equivalent rates (not your subscription bill); **Premium** shows Fast/Ultrafast surcharge, and **Other** shows unsplit provider-reported costs.

- **Retention**: Servers keep scanned usage history for **92 days** by default (preserving Claude history after Claude's 30-day cleanup). Change `usageHistoryRetentionDays` in `<t3-home>/userdata/settings.json` (e.g. `365` or `"unlimited"`; views show up to 90 days).
- **Custom data directories**: Honors `CODEX_HOME`, `CLAUDE_CONFIG_DIR`, `GROK_HOME`, `PI_CODING_AGENT_DIR` / `PI_CODING_AGENT_SESSION_DIR`, `OPENCODE_DATA_DIR`, `ANTIGRAVITY_DATA_DIR`, and `XDG_DATA_HOME` (Muse). Use absolute or `~/` paths. Set `T3CODE_HOST_ID` to pin a container's host identity.
- **Exclusions**: Codex and Claude Code 2.0.63+ text-generation runs (titles, commits, PR text, review guides) and Grok turns without a saved completed-turn record are not included.

## Custom model prices and filtering

- **Custom prices & model mapping**: Open the environment dropdown on **Usage → Model prices** (or click **Set price** on an unpriced model) to set USD per million input/output/cache tokens, or set **Map to** to merge a preview/alias model ID into a target model's totals.
- **Filter models**: Add `usageModelFilter` to `<t3-home>/userdata/settings.json` (applied before **Map to**):

```json
{
  "usageModelFilter": {
    "include": [{ "provider": "claude", "model": "orbit-1" }, { "model": "orbit-2" }],
    "exclude": [{ "model": "drift-9" }]
  }
}
```

## Subscription limits

**Usage → Limits** pools subscription quotas per provider across connected environments and hubs (deduplicating the same account signed in on multiple machines).

- **In chat**: Run `/usage-limits` in the composer to view the current model's snapshot without running the agent, or enable **Settings → Appearance → Thread details → Usage limits** (web/desktop).
- **Reset credits**: Click an account segment/row to inspect plan details and redeem banked reset credits via **Use reset**. Codex grants them when it has rate-limited you unfairly, and Claude subscription plans get the same limit resets Claude.ai offers under **Settings → Usage**. A Claude reset can only be used while you are at a limit, so the action waits until then and says so.
- **On the phone**: **Usage → Accounts** takes the place of Limits: every account on each Infinitus Mac, as on the [Accounts](accounts.md) page.
- **Provider notes**:
  - **OpenCode**: OpenCode 2 servers with usage reporting show Go allowances and Console budgets for the connected workspace. Local servers can also report Go usage from a Go API key (`OPENCODE_API_KEY`).
  - **Cursor**: Reports monthly Auto + API quotas via `CURSOR_AUTH_TOKEN` or default-endpoint sign-in/`CURSOR_API_KEY`.
  - **Grok**: Reports billing-period quotas for `grok login` (not `XAI_API_KEY`).
  - **Muse Code**: Reports session/weekly limits after running in a thread (not persisted across restarts).
  - Pure API-key accounts generally do not report subscription limits.
- **Mobile widget**: Add the **Subscription usage** widget on iOS or Android to monitor Codex and Claude quotas from your home screen. Tap it to open **Usage → Accounts**.

## Hubs and fleets

Accounts pooled behind a hub or an engine (CLIProxyAPI, 9Router, swapd) are read by the Infinitus
app on their Mac and shown on the **Accounts** page, one group per machine, with each account's
windows, banked resets and actions. There is no separate hub list under Settings → Providers.

## Compare activity across machines

Open **Stats** on web or desktop to combine activity from your connected macOS, Linux,
and Windows environments. Use the environment menu to select individual machines.
Older servers need an update before they can report Stats; offline environments are
excluded and the page marks the remaining totals as partial.

Claude and Codex report transcript activity, tokens, and estimated API-equivalent cost.
Grok contributes saved usage totals. Unknown model prices are marked as unpriced; set
prices in **Usage → Model prices** or refresh pricing. Repository statistics use locally
available Git history for the configured Git author; pull-request statistics require
`gh` to be signed in on the environment. Shared sessions, commits, and pull requests
count once across machines. The Data coverage note explains missing metrics.

Stats uses your browser's timezone. Long streaks reaching the retained history boundary
are shown with `≥`. The native Mac Stats view remains local to that Mac.
