# Upstream request — management route for `routing.session-affinity`

**Posted 2026-09-03 as a PR (user: "sure"): router-for-me/CLIProxyAPI#5447**
(fork branch `feat/routing-session-affinity`, targets `dev`): GET/PUT/PATCH
`/v0/management/routing/session-affinity` → `{enabled, ttl}`, persisted
and hot-reloaded like `routing/strategy`. The app gains a toggle next to
the strategy picker that degrades to the YAML note while the proxy lacks
the route (404). Original draft below.

**Title:** Management API: expose `routing.session-affinity` (and TTL) like `routing/strategy`

**Body:**

`GET/PUT/PATCH /v0/management/routing/strategy` lets a management client
switch between fill-first and the round-robin modes at runtime (thanks —
we use it). The companion setting that makes round-robin usable with
Claude Code's prompt cache, `routing.session-affinity` (+
`session-affinity-ttl`), is config-file only today.

A client that flips strategy to `round-robin` therefore can't also turn
affinity on, so the user's first request after the flip lands on a
different credential per request and every prompt-cache read misses
until they edit `config.yaml` by hand.

Request: `GET/PUT /v0/management/routing/session-affinity` returning
`{"enabled": bool, "ttl": "1h"}` with the same persist-to-config +
hot-reload behaviour as `routing/strategy` (config_basic.go
`PutRoutingStrategy`). Read-only would already help (a client could at
least warn).

Context: Infinitus (a macOS menu-bar account manager) drives CLIProxyAPI
purely over the Management API and never touches the config file; the
routing picker in its settings currently has to tell the user to edit
YAML for this one knob. Tested against 7.2.145.
