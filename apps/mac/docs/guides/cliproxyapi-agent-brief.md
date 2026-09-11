# Agent brief: set up CLIProxyAPI for Infinitus

Paste everything below into a coding agent (Claude Code, Codex, …)
running on the machine where Infinitus lives. With `infinitusctl` the
agent does everything except the OAuth click.

---

You are setting up CLIProxyAPI (https://github.com/router-for-me/CLIProxyAPI)
as an account engine for Infinitus, a macOS menu-bar app that manages
several Claude accounts. Infinitus talks to the proxy only over its
Management API on `http://127.0.0.1:8317/v0/management`, authenticated
with the proxy's `remote-management.secret-key`. Do the following, in
order, verifying each step before the next. Never print, log, or commit
secrets; never edit files under `~/.cli-proxy-api/*.json`.

1. **Install and start.** macOS: `brew install cliproxyapi && brew services start cliproxyapi`.
   Linux: run the installer at
   `https://raw.githubusercontent.com/router-for-me/cliproxyapi-installer/refs/heads/master/cliproxyapi-installer`.
   Verify: `curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8317/v0/management/auth-files`
   prints `404` (management API present but disabled) or `401`.

2. **Locate the config.** macOS Homebrew: `$(brew --prefix)/etc/cliproxyapi.conf`.
   Linux/Docker: `~/.cli-proxy-api/config.yaml`. Back it up next to
   itself as `<file>.bak-<date>` before editing.

3. **Generate two secrets** with `openssl rand -hex 24`: one management
   key, one API key. Write them to a mode-600 file the user chooses
   (suggest `~/.cli-proxy-api/infinitus-secrets`): line 1 the management
   key, line 2 the API key, nothing else. Tell the user the file path;
   do not echo the values.

4. **Edit the config** (YAML, keep everything else intact):
   - `remote-management.allow-remote: false`
   - `remote-management.secret-key: "<management key>"` (plaintext —
     the proxy hashes it on start, which is why the copy in step 3 matters)
   - under `api-keys:` replace the placeholder entries with the API key
   - `routing.strategy: "fill-first"` (so Infinitus' Switch is real;
     the proxy default `round-robin` breaks Claude's prompt cache unless
     `routing.session-affinity: true`)

5. **Restart and verify.** `brew services restart cliproxyapi` (or the
   Linux service). Then
   `curl -s -H "Authorization: Bearer $(sed -n 1p <secrets file>)" http://127.0.0.1:8317/v0/management/auth-files`
   must return `{"files":[]}`, and
   `.../v0/management/routing/strategy` must return `{"strategy":"fill-first"}`.

6. **Point Claude Code at the proxy.** Merge into `~/.claude/settings.json`
   (create `env` if missing, keep other keys):
   ```json
   "env": {
     "ANTHROPIC_BASE_URL": "http://127.0.0.1:8317",
     "ANTHROPIC_AUTH_TOKEN": "<API key, not the management key>",
     "CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY": "1"
   }
   ```
   Do this only if the user confirms they want Claude Code routed
   through the proxy from now on; if cswap is their active engine, the
   two fight over the same accounts — ask first.

7. **Connect Infinitus** with its CLI (`Infinitus.app/Contents/MacOS/infinitusctl`;
   run `infinitusctl manifest` first, see `docs/guides/infinitusctl-agent.md`):
   ```sh
   sed -n 1p <secrets file> | infinitusctl proxy-key     # app restarts
   infinitusctl engine cliproxy on                        # app restarts
   infinitusctl proxy                                     # keyPresent:true, enabled:true
   ```
   If `infinitusctl` exits 3, Infinitus is not running: ask the human to
   open it, then retry.

8. **Start the sign-in and hand off.** Per account:
   ```sh
   infinitusctl add cliproxy/claude
   ```
   then tell the human: "Sign in inside the Infinitus window that just
   opened (private sheet or window, never your default browser)." Run
   `infinitusctl wait-add --timeout 300`; it returns the fleets when the
   credential lands. Repeat for each account.

9. **Final check.** `infinitusctl fleets` shows the `cliproxy/claude`
   fleet with each account `"usageStatus":"ok"`, and a new `claude`
   session works. Stop there; do not touch the credential files, and
   never call `infinitusctl remove` without the human's explicit go-ahead.

Reference: `docs/guides/cliproxyapi-setup.md` in the Infinitus repo for
the human-facing walkthrough and the routing/caching notes.
