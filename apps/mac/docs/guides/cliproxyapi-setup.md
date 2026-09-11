# CLIProxyAPI with Infinitus — setup walkthrough

CLIProxyAPI ([router-for-me/CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI))
is a local HTTP proxy that holds several Claude (and Codex/Gemini) OAuth
logins and rotates between them behind one endpoint. Claude Code talks
to the proxy instead of api.anthropic.com; the proxy picks a credential
per request. Infinitus drives it purely over its Management API — it
never reads the proxy's config or credential files.

How it differs from cswap: cswap **swaps the credential under Claude
Code** (one account active at a time, switched when limited). The proxy
**rotates behind its own endpoint** (Claude Code never sees which
account served a request). Run one engine per account set — both on the
same accounts fight each other.

Verified against CLIProxyAPI 7.2.145 on macOS, 2026-09-02.

## 1. Install and start the proxy

```sh
brew install cliproxyapi
brew services start cliproxyapi
```

Linux one-liner: `curl -fsSL https://raw.githubusercontent.com/router-for-me/cliproxyapi-installer/refs/heads/master/cliproxyapi-installer | bash`.
Docker: `eceasy/cli-proxy-api:latest` on port 8317 with `config.yaml`
and the auth dir mounted (see the proxy's quick start).

The proxy listens on `http://127.0.0.1:8317`. Config lives at
`$(brew --prefix)/etc/cliproxyapi.conf` (Homebrew) or
`~/.cli-proxy-api/config.yaml` (Linux/Docker); credentials land in
`~/.cli-proxy-api/*.json`.

## 2. Turn on the Management API

Edit the config and set a management key. The value you write is
**plaintext**; the proxy hashes it on its next start, so keep the
plaintext somewhere safe (a password manager) — Infinitus needs it.

```yaml
remote-management:
  allow-remote: false        # localhost only — fine for Infinitus
  secret-key: "paste-a-long-random-string-here"
```

Also give Claude Code a key to use on the proxy's API side:

```yaml
api-keys:
  - "another-long-random-string"
```

Restart: `brew services restart cliproxyapi`.

Check: `curl -s -H "Authorization: Bearer <management-key>" http://127.0.0.1:8317/v0/management/auth-files`
should answer `{"files":[]}` (not 404 — 404 means the key line is empty).

The proxy also bundles a web control panel at
`http://127.0.0.1:8317/management.html`
([Cli-Proxy-API-Management-Center](https://github.com/router-for-me/Cli-Proxy-API-Management-Center)).
You can use it alongside Infinitus; both speak the same Management API.

## 3. Connect Infinitus

From a shell (or let an agent do it, `docs/guides/infinitusctl-agent.md`):

```sh
CTL=/Applications/Infinitus.app/Contents/MacOS/infinitusctl
printf '%s' '<management key>' | $CTL proxy-key   # app restarts
$CTL engine cliproxy on                           # app restarts
```

Or by hand:

1. Open Infinitus → Settings → **CLIProxyAPI** tab.
2. Base URL: leave empty for `http://127.0.0.1:8317`.
3. Management key: paste the plaintext key → **Test connection** →
   "reachable — 0 credential files, routing fill-first".
4. **Save & restart.** The key goes into the keychain
   (`run.infinitus.cliproxy`), never into defaults or logs.
5. Flip **Engine on**. The app restarts with the proxy fleet registered.

If cswap is also on you get the layer-fight warning under the toggle.
Turn cswap off unless the two engines hold different accounts.

## 4. Add accounts

Settings → **Accounts** tab → the "Claude — CLIProxyAPI" section →
**Add account…**. The same chooser as cswap appears: a private system
sign-in sheet, or a per-account private window (its cookie jar is keyed
by email and shared with cswap's sign-ins, so a second engine holding
the same account doesn't ask you to log in twice). Your default browser
is never used.

Sign in, approve, and the credential appears in the section within a
few seconds (Infinitus polls the proxy's auth state; the proxy runs the
OAuth callback on port 54545 itself). Repeat per account.

Per account you get the same controls as cswap: usage gauges, **Switch**
(raises the credential to the top priority tier), **Hold** (proxy
`disabled`), rename (proxy `note`), **Relogin**, and remove.

## 5. Point Claude Code at the proxy

In `~/.claude/settings.json`:

```json
{
  "env": {
    "ANTHROPIC_BASE_URL": "http://127.0.0.1:8317",
    "ANTHROPIC_AUTH_TOKEN": "another-long-random-string",
    "CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY": "1"
  }
}
```

`ANTHROPIC_AUTH_TOKEN` is one of the proxy's `api-keys`, not the
management key. Start a new `claude` session; the proxy's auth-files
`success` counters tick up as it serves requests.

## 6. Routing

Settings → CLIProxyAPI → **Routing**:

| Strategy | What it does | Prompt cache |
|---|---|---|
| `fill-first` (recommended) | Highest priority credential until it is rate-limited — cswap's consume-first. Switch works. | Fine: one account per conversation. |
| `round-robin` (proxy default) | Every request goes to the next credential. | **Misses** unless session affinity is on. Switch is advisory. |
| `weighted-round-robin` | Rotation proportional to each credential's `weight`. | Same as round-robin. |

Session affinity keeps one conversation on one credential under the
round-robin modes. It is **config only** (no management route yet — see
`docs/research/upstream-session-affinity-route.md`):

```yaml
routing:
  strategy: "round-robin"
  session-affinity: true
  session-affinity-ttl: "1h"
```

Under affinity an existing session stays on its credential even after
you Switch; Switch only steers new sessions.

## 7. Usage polling and 429s

Anthropic's usage endpoint rate-limits per **account**. Infinitus polls
each proxy credential once per 5 minutes, dedupes credentials that
share an email, reuses usage cswap already fetched for the same email,
and backs a credential off for 5 minutes on a 429. If a gauge reads
"error" right after adding an account, wait a poll or two.

## Troubleshooting

- **Test connection: 401/404** — wrong key, or `secret-key` empty (404)
  or not yet hashed (restart the proxy after editing).
- **Sign-in tab lands on `localhost:54545` with connection refused** —
  old Infinitus build; the proxy only starts that callback forwarder
  when asked with `is_webui=true`, which Infinitus does since 385434d.
- **"round-robin routing ignores priority — switch is advisory"** in the
  section header — expected; pick fill-first or turn on affinity.
- **Two credentials, one email** — allowed; they share one usage poll
  and show the same gauges.
- Infinitus never edits the proxy's config or auth files; anything
  above marked YAML is yours to change (or use the control panel).
