---
name: drive-phone
description: Drive the developer's paired physical iPhone (Titan) from a session to reproduce and troubleshoot the Infinitus phone app on real hardware, including rebuilding and installing a Release build, launching the app, opening a deep link, screenshots, accessibility snapshots, taps, and the app's console. Use when a phone-only report cannot be reproduced on a simulator, when a fix must be verified on the device, or when the user asks to check something on Titan.
---

# Drive the phone

`scripts/phone.sh` wraps the `agent-device` CLI the server pins, with the
state directory and runner signing set for this repository. Everything a
command needs beyond that is a flag: `--platform ios --device Titan`.
Simulator work stays with [`test-t3-mobile`](../test-t3-mobile/SKILL.md).

## What works without anything else

The phone must be paired, cabled or on the Mac's network, and unlocked.

```bash
scripts/phone.sh devices --platform ios
scripts/phone.sh open run.infinitus.mobile --platform ios --device Titan --foreground
scripts/phone.sh open "t3code://settings/environments" --platform ios --device Titan
scripts/phone.sh screenshot --platform ios --device Titan --out /tmp/titan.png
scripts/phone.sh logs start --platform ios --device Titan
scripts/phone.sh logs path --platform ios --device Titan
scripts/phone.sh close --platform ios --device Titan
```

Launch, deep links, screenshots and the console go through CoreDevice and
need no runner. Deep links use the app's `t3code://` scheme; the settings
stack's paths are the `linking` values in `apps/mobile/src/Stack.tsx`
(`settings/environments` is the Connect list).

A Release build has no JavaScript console: `console.error` from the app never
reaches the stream. The stream shows native output only. To read an app-level
error, make the app display it and take a screenshot.

## Snapshots and taps need the runner

`snapshot -i`, `press`, `fill` and friends run through an XCTest runner that
`agent-device` builds, signs with team `Q783W6B4FA` as
`run.infinitus.agentdevice.runner`, and installs on the phone the first time.
Two prerequisites:

- The Mac's developer tools security must be on. Check with
  `DevToolsSecurity -status`. Turning it on is `sudo DevToolsSecurity -enable`,
  which is the user's step: ask, never run it.
- Developer Mode on the phone (Settings › Privacy & Security), already on
  for Titan.

Until both hold, `open` still succeeds and reports the snapshot failure as a
warning. Screenshots keep working.

## Rebuild and install

From a worktree whose `.env` carries the relay's public config
(`T3CODE_CLERK_JWT_TEMPLATE=infinitus-relay`, the value GitHub's
`production` environment gives releases; a `t3-relay` left over from before
#1388 builds a phone that cannot mint tokens) and `APP_VARIANT=infinitus`:

```bash
cd apps/mobile
APP_VARIANT=infinitus EXPO_NO_GIT_STATUS=1 CI=1 \
  expo prebuild --clean --platform ios
APP_VARIANT=infinitus CI=1 \
  expo run:ios --device 00008110-000631E81409801E --configuration Release --no-bundler
```

Set `APP_VARIANT` on both commands: prebuild reads it for the bundle id and
team, the Xcode bundle step reads it again for the embedded app config. A
locked phone fails only the final launch; the install has landed. Confirm
with `xcrun devicectl device info apps --device <udid>` and the
`EXConstants.bundle/app.config` inside the built `.app` under DerivedData
(`extra.appVariant`, `extra.clerk.jwtTemplate`, `extra.relay.url`).

## Rules

- Screenshots capture whatever is on screen, lock screen and notifications
  included. Read them, delete them, never attach or commit one.
- Close the session when done so the runner and daemon stop.
- One phone, one session. Do not relaunch the app (`--relaunch`) while the
  user may be using it; `open` without it only brings the app forward.
