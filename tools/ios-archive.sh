#!/bin/bash
# Archives the phone app for App Store Connect and exports (or uploads)
# the .ipa (#143). Release, generic iOS device, automatic signing on the
# team in ios/project.yml; ios/ExportOptions.plist holds the export
# method. Human prerequisites (docs/RELEASING.md § Phone): an App Store
# Connect record for run.infinitus.mobile and, for the first export, an
# Apple Distribution certificate — pass --provision once to let Xcode mint
# it and the App Store profiles (a developer-portal write).
#
#   tools/ios-archive.sh [--build N] [--upload] [--provision]
#
# --build N   CURRENT_PROJECT_VERSION for this archive (TestFlight refuses
#             a repeated build number; project.yml keeps the marketing
#             version).
# --upload    hand the export to App Store Connect. Authenticates with the
#             notarization API key (NOTARY_KEY_ID / NOTARY_ISSUER_ID from
#             .env, the .p8 at ~/.private_keys/AuthKey_<id>.p8 or
#             NOTARY_KEY_PATH). Notarization accepts a Developer-role
#             key; if the upload is refused, check the key's role against
#             Apple's role table (App Store Connect → Users and Access).
# Output: ios/build/archive/InfinitusMobile.xcarchive and, without
# --upload, ios/build/archive/export/InfinitusMobile.ipa.
set -euo pipefail
cd "$(dirname "$0")/.."

BUILD="" UPLOAD=0 PROVISION=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --build) BUILD="$2"; shift 2 ;;
    --upload) UPLOAD=1; shift ;;
    --provision) PROVISION=(-allowProvisioningUpdates); shift ;;
    *) echo "usage: $0 [--build N] [--upload] [--provision]" >&2; exit 2 ;;
  esac
done
[[ -f .env ]] && set -a && . ./.env && set +a

OUT=ios/build/archive
ARCHIVE="$OUT/InfinitusMobile.xcarchive"
rm -rf "$ARCHIVE" "$OUT/export"
(cd ios && xcodegen generate -q)
xcodebuild -quiet -skipPackagePluginValidation -project ios/InfinitusMobile.xcodeproj -scheme InfinitusMobile \
  -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath ios/build -archivePath "$ARCHIVE" \
  ${BUILD:+CURRENT_PROJECT_VERSION="$BUILD"} "${PROVISION[@]+"${PROVISION[@]}"}" archive
echo "archived $ARCHIVE"

OPTIONS=ios/ExportOptions.plist
AUTH=()
if [[ $UPLOAD -eq 1 ]]; then
  : "${NOTARY_KEY_ID:?set NOTARY_KEY_ID (App Store Connect API key id)}"
  : "${NOTARY_ISSUER_ID:?set NOTARY_ISSUER_ID}"
  KEY="${NOTARY_KEY_PATH:-$HOME/.private_keys/AuthKey_${NOTARY_KEY_ID}.p8}"
  [[ -f "$KEY" ]] || { echo "no API key at $KEY" >&2; exit 1; }
  OPTIONS="$OUT/ExportOptions.upload.plist"
  plutil -replace destination -string upload -o "$OPTIONS" ios/ExportOptions.plist
  AUTH=(-authenticationKeyPath "$KEY" -authenticationKeyID "$NOTARY_KEY_ID" -authenticationKeyIssuerID "$NOTARY_ISSUER_ID")
fi
xcodebuild -quiet -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist "$OPTIONS" \
  -exportPath "$OUT/export" "${AUTH[@]+"${AUTH[@]}"}" "${PROVISION[@]+"${PROVISION[@]}"}"
if [[ $UPLOAD -eq 1 ]]; then echo "uploaded to App Store Connect"; else echo "exported $OUT/export/InfinitusMobile.ipa"; fi
