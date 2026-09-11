# Infinitus team members on Windows

**Best-effort.** There is no tray or menu bar app on Windows, and no
release asset. CI does build InfinitusCore and `infinitusctl` on a
`windows-2022` runner, but that job is allowed to fail and is red today:
it compiles nearly all of InfinitusCore and then stops. Everything below
assumes you got the binary built. Reports welcome.

## Build the CLI

With the [Swift 6.1 toolchain](https://www.swift.org/install/windows/)
and vcpkg's zlib, in a Developer Command Prompt:

```
vcpkg install zlib:x64-windows
swift build -c release --product infinitusctl ^
  -Xcc -IC:/vcpkg/installed/x64-windows/include ^
  -Xswiftc -LC:/vcpkg/installed/x64-windows/lib
```

Copy `.build\release\infinitusctl.exe` somewhere stable — the snippets
below use `C:\Program Files\Infinitus\infinitusctl.exe`; there is no
installer, so put it wherever you like and edit the paths to match.

## Join a team

Ask a leader for a team code and pass it on **stdin** — the code carries
the store's write credential and a command line is not private:

```
infinitusctl team request - --name "Your Name"
```

Paste the code, then Ctrl-Z and Enter. `infinitusctl team status` shows
where you stand; a leader approves from the Mac, the phone or
`infinitusctl team approve <kid>`. On a trusted LAN, `infinitusctl team
nearby` and `infinitusctl team request --nearby <kid> --name "Your Name"`
skip the code — or let the leader invite you: `infinitusctl team
nearby invite <kid|name>` on their end, then `infinitusctl team invites`
to see it and `infinitusctl team accept <kid> --name "Your Name"` to
join (`infinitusctl team ignore <kid>` deletes it instead).

## Sync on a timer

`fetch` pulls the store and accepts the roster; `publish` pushes your
stats, sessions and chosen transcripts, end-to-end encrypted to the
readers you picked. Two Scheduled Tasks, both every five minutes — run
these in `cmd.exe`, where the inner quotes are escaped with `\`:

```
schtasks /Create /SC MINUTE /MO 5 /ST 00:00 /TN "Infinitus Team Fetch" ^
  /TR "\"C:\Program Files\Infinitus\infinitusctl.exe\" team fetch"

schtasks /Create /SC MINUTE /MO 5 /ST 00:02 /TN "Infinitus Team" ^
  /TR "\"C:\Program Files\Infinitus\infinitusctl.exe\" team publish"
```

`/ST` sets where each recurrence starts, so publish runs two minutes
after each fetch. The gap is a courtesy, not a requirement: a publish
that lands on a moved remote pulls and pushes again by itself.

`schtasks /Query /TN "Infinitus Team" /V /FO LIST` shows the last result;
`schtasks /Delete /TN "Infinitus Team" /F` removes one.

## What you control

```
infinitusctl team share transcripts off
infinitusctl team exclude C:\work\private-repo
infinitusctl team members --period week
infinitusctl team identity recovery --show
```

The kinds are `stats`, `now`, `sessions`, `transcripts` and `crashes`;
`off` keeps a kind on this machine entirely. `infinitusctl team --help`
lists every subcommand; the Mac README's Team section walks the whole
flow.
