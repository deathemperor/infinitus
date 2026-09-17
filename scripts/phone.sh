#!/bin/sh
# Drives a paired physical iPhone from a session with the `agent-device` CLI
# the server already pins (apps/server/src/device/DeviceToolchain.ts), so a
# session can launch the app, open a deep link, screenshot the screen and read
# the app's console on the developer's own phone. Nothing is installed on the
# Mac: the CLI lives under this worktree's gitignored `.t3/tools`, its daemon
# state under `.t3/agent-device`, and the on-device XCTest runner it signs
# for taps and snapshots is an app on the phone. Usage and traps:
# `.agents/skills/drive-phone/SKILL.md`.
#
#   scripts/phone.sh devices --platform ios
#   scripts/phone.sh open run.infinitus.mobile --platform ios --device Titan --foreground
#   scripts/phone.sh open "t3code://settings/environments" --platform ios --device Titan
#   scripts/phone.sh screenshot --platform ios --device Titan --out /tmp/titan.png
#
# Environment:
#   INFINITUS_PHONE_TEAM_ID    signing team for the runner (default: Q783W6B4FA)
#   INFINITUS_PHONE_RUNNER_ID  runner bundle id (default: run.infinitus.agentdevice.runner)
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
version=$(sed -n 's/^export const AGENT_DEVICE_VERSION = "\([^"]*\)";$/\1/p' \
  "$root/apps/server/src/device/DeviceToolchain.ts")
[ -n "$version" ] || { echo "phone.sh: AGENT_DEVICE_VERSION not found in DeviceToolchain.ts" >&2; exit 1; }

prefix="$root/.t3/tools/agent-device/$version"
cli="$prefix/node_modules/agent-device/bin/agent-device.mjs"
if [ ! -f "$cli" ]; then
  echo "phone.sh: installing agent-device@$version under .t3/tools" >&2
  mkdir -p "$prefix"
  npm install --prefix "$prefix" --no-audit --no-fund --ignore-scripts --silent "agent-device@$version"
fi

export AGENT_DEVICE_STATE_DIR="$root/.t3/agent-device"
export AGENT_DEVICE_IOS_TEAM_ID="${INFINITUS_PHONE_TEAM_ID:-Q783W6B4FA}"
export AGENT_DEVICE_IOS_BUNDLE_ID="${INFINITUS_PHONE_RUNNER_ID:-run.infinitus.agentdevice.runner}"
exec node "$cli" "$@"
