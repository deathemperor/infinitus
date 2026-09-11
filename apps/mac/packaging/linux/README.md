# Infinitus team members on Linux

There is no menu bar app here (it's AppKit), but a team member doesn't
need one: `infinitusctl team` runs **in-process** — no app, no control
socket — so the CLI alone publishes your stats and reads what teammates
share with you. Everything else `infinitusctl` does needs the Mac app
and says so.

## Build the CLI

No release asset ships `infinitusctl` for Linux — the release publishes
the Waybar/Quickshell binary (`infinitus-tray-linux-*`) only, so build
this one from source. In a container (any box with Docker):

```sh
docker run --rm -v "$PWD":/src -w /src swift:6.1 \
  swift build -c release --product infinitusctl -Xswiftc -static-stdlib
install -Dm755 .build/release/infinitusctl ~/.local/bin/infinitusctl
```

`-static-stdlib` keeps the Swift runtime out of the way: the binary needs
only glibc/libstdc++. A native toolchain works too — same command without
the `docker run` prefix. One `--product` per invocation: with two flags
SwiftPM builds only the last.

## Join a team

Ask a leader for a team code, then pass it on **stdin** — the code
carries the store's write credential and argv is world-readable:

```sh
infinitusctl team request - --name "Your Name"   # paste the code, then Ctrl-D
infinitusctl team status
```

A leader approves you from the Mac, the phone, or `infinitusctl team
approve <kid>`. On the same network you can skip the code entirely: a
leader runs `infinitusctl team --discoverable` (or turns Nearby on in
the Mac's Team pane) and you send the request straight over the LAN:

```sh
infinitusctl team nearby                                  # list machines
infinitusctl team request --nearby <kid> --name "Your Name"
```

Or let the leader come to you: they run `infinitusctl team nearby
invite <kid|name> [--days N]` against your discoverable machine, you
list it with `infinitusctl team invites`, then `infinitusctl team
accept <kid> --name "Your Name"` joins (`infinitusctl team ignore <kid>`
deletes it instead).

The biometric lock the Mac and the phone gate joining behind has no
Linux counterpart yet, so the CLI is open here by design.

## Sync on a timer

`fetch` pulls the store and accepts the roster; `publish` pushes your
stats, sessions and chosen transcripts, end-to-end encrypted to the
readers you picked. Run them every 5 minutes as user units:

```sh
install -Dm644 packaging/linux/infinitus-team.service \
  ~/.config/systemd/user/infinitus-team.service
install -Dm644 packaging/linux/infinitus-team.timer \
  ~/.config/systemd/user/infinitus-team.timer
systemctl --user daemon-reload
systemctl --user enable --now infinitus-team.timer
```

`systemctl --user list-timers infinitus-team.timer` shows the next run,
`journalctl --user -u infinitus-team.service` the last one. The units
call `%h/.local/bin/infinitusctl` — edit `ExecStart=` if yours lives
elsewhere. `Persistent=true` catches up a run the machine slept through.
A laptop that logs out should keep the timer alive with
`loginctl enable-linger $USER`.

## What you control

```sh
infinitusctl team share transcripts off       # or: leaders, team, <kid>[,<kid>…]
infinitusctl team exclude ~/work/private-repo # never published, local only
infinitusctl team members --period week       # what teammates share with you
infinitusctl team identity recovery --show    # keep this offline
```

The kinds are `stats`, `now`, `sessions`, `transcripts` and `crashes`;
`off` keeps a kind on this machine entirely. Narrowing an audience only
affects new envelopes — it cannot recall ciphertext teammates already
fetched. `infinitusctl team --help` lists every subcommand. Leaving a
team is a Mac action today (Settings › Team › Leave).
