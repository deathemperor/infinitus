#!/bin/sh
# Assemble Infinitus.app from the release build (parity checklist: proper
# notification identity). LSUIElement keeps it out of the Dock; the bundle
# identifier is what lets UNUserNotificationCenter work (Notifier.swift).
set -eu
cd "$(dirname "$0")"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/Infinitus"
APP=Infinitus.app

VERSION="$(head -1 VERSION 2>/dev/null | tr -cd '0-9A-Za-z.-')"
SHA="$(git rev-parse --short HEAD 2>/dev/null || echo dev)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Infinitus"
cp "$(dirname "$BIN")/infinitusctl" "$APP/Contents/MacOS/infinitusctl"
[ -f AppIcon.icns ] || ./make-icon.sh
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp tools/demo-cswap "$APP/Contents/Resources/demo-cswap"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>Infinitus</string>
    <!-- run.infinitus (2026-09-05, user-approved, explicit ask): the
         reverse-DNS of infinitus.run, alongside the phone's
         run.infinitus.mobile on the paid team. Notification and
         login-item grants key on the id — re-grant both after this;
         keychain items under the old id are not readable (re-enter).
         Prefs migrate in-app from com.huuloc.infinitus (2026-09-03 id)
         ← com.huuloc.limitless (2026-08-30) ← io.github.claude-swap.CswapBar.g2,
         a rename away from a persistent macOS 26 ControlCenter per-id
         ban acquired in the 2026-08-29 MenuBarExtra insert/evict war.
         Never change casually. -->
    <key>CFBundleIdentifier</key><string>run.infinitus</string>
    <key>CFBundleName</key><string>Infinitus</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION:-0.0.0}</string>
    <key>CFBundleVersion</key><string>${SHA}</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>CFBundleURLTypes</key><array><dict>
        <key>CFBundleURLName</key><string>run.infinitus.join</string>
        <key>CFBundleURLSchemes</key><array><string>infinitus</string></array>
    </dict></array>
    <key>LSUIElement</key><true/>
    <key>NSLocalNetworkUsageDescription</key><string>Infinitus advertises the fleet snapshot to the Infinitus iPhone app on your local network (Sync → Phone companion).</string>
    <key>NSBonjourServices</key><array><string>_infinitus._tcp</string></array>
</dict>
</plist>
PLIST
# Signing identity, in order: SIGN_IDENTITY (the release workflow sets it
# from an imported Developer ID cert), a Developer ID Application cert in
# the keychain, an Apple Development cert (local builds: Notification
# Center refuses ad-hoc-signed apps, and an ad-hoc grant would not survive
# rebuilds anyway), else ad-hoc. Developer ID builds get the hardened
# runtime + a secure timestamp, which notarization requires (RELEASING.md).
find_identity() {
    security find-identity -v -p codesigning 2>/dev/null \
        | awk -F'"' -v pat="$1" '$0 ~ pat {print $2; exit}'
}
IDENTITY="${SIGN_IDENTITY:-}"
[ -n "$IDENTITY" ] || IDENTITY="$(find_identity 'Developer ID Application')"
[ -n "$IDENTITY" ] || IDENTITY="$(find_identity 'Apple Development')"
# Inside-out: a codesign of the bundle leaves the nested infinitusctl on
# its ad-hoc linker signature, which notarization rejects ("binary is not
# signed with a valid Developer ID certificate"), so the helper is signed
# first with the same flags, then the bundle.
# Passkeys (spec §2.1) need the associated-domains entitlement, which only
# a provisioning profile can carry: PROVISIONING_PROFILE=<path to a
# .provisionprofile for run.infinitus> embeds it and signs the bundle with
# Infinitus.entitlements. Without it (the dev loop, CI) nothing changes —
# a dev-signed build has no passkey path, and the local identity is the
# default anyway.
ENTITLEMENTS=""
if [ -n "${PROVISIONING_PROFILE:-}" ]; then
    [ -f "$PROVISIONING_PROFILE" ] || { echo "PROVISIONING_PROFILE not found: $PROVISIONING_PROFILE"; exit 2; }
    cp "$PROVISIONING_PROFILE" "$APP/Contents/embedded.provisionprofile"
    ENTITLEMENTS="--entitlements Infinitus.entitlements"
fi
case "$IDENTITY" in
    "Developer ID Application"*)
        codesign --force --options runtime --timestamp --sign "$IDENTITY" \
            "$APP/Contents/MacOS/infinitusctl"
        codesign --force --options runtime --timestamp --sign "$IDENTITY" $ENTITLEMENTS "$APP" ;;
    *)
        codesign --force --sign "${IDENTITY:--}" "$APP/Contents/MacOS/infinitusctl"
        codesign --force --sign "${IDENTITY:--}" $ENTITLEMENTS "$APP" ;;
esac
echo "Built $PWD/$APP — launch with: open $APP"
