#!/bin/sh
# Build AppIcon.icns from make-icon.swift's 1024px master. Idempotent-ish:
# make-app.sh only calls this when AppIcon.icns is missing; run it by hand
# after changing make-icon.swift.
set -eu
cd "$(dirname "$0")"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
swift make-icon.swift "$TMP/icon_1024.png"

SET="$TMP/AppIcon.iconset"
mkdir "$SET"
for s in 16 32 128 256 512; do
    sips -z "$s" "$s" "$TMP/icon_1024.png" --out "$SET/icon_${s}x${s}.png" >/dev/null
    d=$((s * 2))
    sips -z "$d" "$d" "$TMP/icon_1024.png" --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o AppIcon.icns
echo "Built $PWD/AppIcon.icns"
