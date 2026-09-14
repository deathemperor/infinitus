# Infinitus on Omarchy (and other Waybar/Linux desktops)

The macOS app can't port (AppKit), but its Swift core does:
`infinitus-tray` is the same fleet — live gauges, themes, sentinel
notes, one-click rotate — as a Waybar `custom` module. The engine
stays behind `swapd … --json`, exactly like the app.

## Install

1. Engine: `cargo install --git https://github.com/deathemperor/swapd swapd`
   (the same swapd the Mac app drives). Log accounts in with Claude
   Code, then `swapd add`.
2. Binary — build once in a container (any box with Docker):

   ```sh
   docker run --rm -v "$PWD":/src -w /src swift:6.1 \
     swift build -c release -Xswiftc -static-stdlib
   install -Dm755 .build/release/infinitus-tray ~/.local/bin/infinitus-tray
   ```

   `-static-stdlib` keeps the runtime out of the way: the binary needs
   only glibc/libstdc++, present on every Arch install. (Native builds
   work too if you have a Swift toolchain.)
3. Waybar: merge `waybar-infinitus.jsonc` into your Waybar config's
   modules, append `style.css` to your Waybar stylesheet, reload.

## Use

- Bar text: active account + 5h·7d percentages (`--remaining` flips
  them to what's left).
- Tooltip: the whole fleet, themed — `--theme rpg` turns percentages
  into MP/HP, dead accounts into 💀 with a revive countdown.
  `infinitus-tray themes` lists all 15 built-ins.
- Click: rotate to the next account (`signal: 8` refreshes instantly).
- CSS classes `ok` / `warning` / `dead` / `error` mirror the active
  account's state.

Estimates shown are never billing truth; the module reads nothing of
the engine's internals.

The footer chips (service status, live-session count, auto-switch
engine badge) come from the same poll: Anthropic's status page is
fetched at most once every 5 minutes (cached under
`$XDG_CACHE_HOME/infinitus`, falling back to "unknown" offline), and
the engine badge just checks whether a `swapd auto` process is alive
(`pgrep -f "swapd auto"`) — the Linux tray has no supervisor of its own
to start or stop it.

## The daemon: `infinitus-tray serve`

`infinitus-tray serve` is the tray's one long-running process: it binds
the control socket (`infinitusctl status` and the hooks reach this box
through it) and re-collects the fleet every 30 s (`--interval S`) to
tick the away-push triggers (#13 parity: all accounts exhausted, last
account standing) — `status`/`panel` are one-shot execs with no state
to carry a multi-tick episode across, so only `serve` can do this. Each
firing message is shown by `notify-send` if it's on `PATH`, and logged
to stderr. Gate each trigger with an env var (default on for both):

```sh
INFINITUS_PUSH_ALL_DEAD=0        # off: "all accounts exhausted"
INFINITUS_PUSH_LAST_ALIVE=0      # off: "last account standing"
```

Run it under systemd (`packaging/omarchy/infinitus-serve.service`):

```sh
install -Dm644 packaging/omarchy/infinitus-serve.service \
  ~/.config/systemd/user/infinitus-serve.service
systemctl --user daemon-reload
systemctl --user enable --now infinitus-serve
```

The phone no longer pairs with the tray: its mirror server and pairing
token left with #1219 (the phone pairs through the desktop app).

## Omarchy 4+ (Quickshell bar)

Newer Omarchy replaced Waybar with a Quickshell shell. The same
`infinitus-tray` binary drives a native bar plugin instead:

1. Copy `quickshell-plugin/infinitus/` to `~/.config/omarchy/plugins/infinitus/`
   (the shell hot-reloads local plugins).
2. Add `{ "id": "infinitus.fleet" }` to `bar.layout.right` in
   `~/.config/omarchy/shell.json` — a plugin is enabled by being
   referenced there.
3. The widget execs `~/.local/bin/infinitus-tray` — install the binary
   (or a wrapper) at that path. Theme id and refresh interval live in
   the widget's settings (`barWidget.schema`).

Clicking the bar label (any button) opens the fleet panel — the popup
UI, matching the macOS app: per-account rows with usage gauges (dead,
sentinel, and disabled states rendered like the macOS popup; a window
running behind its weekly pace breathes a mint sheen; a row whose
binding window reaches the 90s pulses an urgent border; a row dead on
its 5h window alone keeps its weekly/per-model gauges, timers
skipped), click a row to
switch to that account, right-click a row to hold it out of rotation
(or return it), rotate + theme stepper in the footer. Rows sort by
headroom with the active account and next candidate on top (the
`sortByHeadroom` setting; off = engine slot order). When every account
is at a limit the header counts down to the first one back — and says
how many limit-stopped sessions wait to resume. Keys while open:
`1`–`9` switch, `r` rotate, `[`/`]` step the theme, Escape closes.
IPC drives it too:
`qs ipc -i <instance> call infinitus.fleet toggle` (also `rotate`,
`refresh`, `cycleTheme`).

Development note: the shell hot-reloads plugin files but serves QML
from a component cache — after editing the plugin's QML, restart the
shell to actually pick the change up.

Building natively on Arch instead of the Docker route: the official
ubuntu24.04 toolchain tarball runs fine with three symlink shims
(`libncurses.so.6` and `libtinfo.so.6` -> `libncursesw.so.6`,
`libxml2.so.2` -> `libxml2.so.16`) on `LD_LIBRARY_PATH`; the built
binary needs the toolchain's `usr/lib/swift/linux` on its runtime
`LD_LIBRARY_PATH` too (or `-static-stdlib`).
