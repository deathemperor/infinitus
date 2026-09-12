# infinitusctl — the agent guide

`infinitusctl` lets a coding agent read and drive the running Infinitus
app from a shell: which accounts exist, their usage, switch/hold/rename,
engine on/off, proxy setup, and starting a sign-in. It is bundled at
`Infinitus.app/Contents/MacOS/infinitusctl` (and `ictl`, the same binary
under a short name); symlink it onto `$PATH` or
call it by that path.

Talks to the app over `~/Library/Application Support/Infinitus/control/control.sock`
(a 0700 directory owned by you — that is the auth). The app must be running.
`INFINITUS_CONTROL_SOCKET=<path>` overrides the socket on both ends — set it
on a playground/dev instance and on `infinitusctl` to drive that instance
instead of the real app (the playground opens no socket without it).

Installing from scratch instead? Start with `agent-setup.md` in this
directory; this guide is for the app once it runs.

## The one rule

**Run `infinitusctl manifest` first.** It returns every command with its
arguments, effect class, the engine capability it needs, and the reply
shape, straight from the table the app dispatches on. Anything in this
file that disagrees with the manifest is out of date; the manifest wins.

## Effects

| effect | meaning | what to do |
|---|---|---|
| `read` | reads state | always safe |
| `write` | reversible engine change | just do it |
| `destructive` | deletes a credential | requires `--yes`; confirm with the human first |
| `restart` | the app relaunches | the CLI waits for the socket to come back before exiting |
| `human` | starts something a person must finish | tell the human, then `wait-add` |

## Exit codes

`0` ok · `1` the command failed (reason on stderr) · `2` usage · `3` app
not running · `4` the app speaks a newer schema; update the CLI.

## Commands (schema 1)

```
infinitusctl status                          app version, engines on/off, badge, sign-in running?
infinitusctl fleets                          every fleet: accounts, usage, active/next, capabilities
infinitusctl refresh                         poll engines now, then like fleets
infinitusctl switch  <fleet> <n>
infinitusctl rotate  <fleet>                 switch to the engine's next candidate
infinitusctl hold    <fleet> <n>
infinitusctl unhold  <fleet> <n>
infinitusctl rename  <fleet> <n> <alias>     "" clears
infinitusctl prefer  <fleet> <n> on|off        star: the engine lands on it first (swapd `prefer`, proxy priority)
infinitusctl reorder <fleet> <n>...          every account once, top first
infinitusctl remove  <fleet> <n> --yes
infinitusctl add     <fleet>                 opens the in-app sign-in; human finishes it
infinitusctl wait-add [--timeout 300]        blocks until that sign-in ends
infinitusctl show    popout|settings|wall
infinitusctl windows                         every app window: visible? size, content class
infinitusctl events [--limit 100]            the app's event log (switches, deaths, revivals, nudges), oldest first
infinitusctl stats [--period week]          engineering metrics: commits, lines, PRs, messages by source, sessions, waiting, switches, cost
infinitusctl perf                            cpuSeconds/rssBytes/heapBytes/threads — sample twice for an idle % and heap growth
infinitusctl engine  swapd|cliproxy|9router on|off   restarts the app
infinitusctl proxy                           base URL, key stored?, routing strategy
infinitusctl proxy-key [--url U] < keyfile   key from stdin, never argv; restarts the app
infinitusctl proxy-routing fill-first|round-robin|weighted-round-robin
```

`<fleet>` is a key from `fleets`, e.g. `swapd/claude` or `cliproxy/claude`.
`<n>` is the account number inside that fleet. Every account action
returns the refreshed fleet so you can verify without a second call.

## Recipes

Pick the account with the most weekly headroom and switch to it:

```sh
infinitusctl fleets | jq -r '.[] | select(.key=="swapd/claude") | .accounts
  | map(select(.usageStatus=="ok")) | min_by(.usage.sevenDay.pct) | .number' \
  | xargs infinitusctl switch swapd/claude
```

Set up the CLIProxyAPI engine (after the proxy itself is configured, see
`cliproxyapi-setup.md`):

```sh
printf '%s' "$MANAGEMENT_KEY" | infinitusctl proxy-key      # app restarts
infinitusctl engine cliproxy on                              # app restarts
infinitusctl proxy-routing fill-first
infinitusctl add cliproxy/claude   # tell the human: sign in in the Infinitus window
infinitusctl wait-add --timeout 300 && infinitusctl fleets
```

## Don'ts

- Never pass secrets on the command line; `proxy-key` reads stdin.
- Never call `remove` without the human's explicit go-ahead.
- Do not edit `~/.claude/settings.json`, the proxy's config, or anything
  under `~/.claude-swap-backup/` on the app's behalf; those are the
  human's or the engine's.
