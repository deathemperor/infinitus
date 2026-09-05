#!/usr/bin/env bash
#
# Infinitus signing wizard — Developer ID + notarization for the Mac app,
# the paid team for the phone app, the APNs key for Live Activity push.
# Walks the human through the portal steps and runs the local checks
# (docs/RELEASING.md). Re-runnable; values persist outside the repo.
#
# Everything above the "STAGES" marker is the wizard library: do not hand-edit
# it. Author the per-step stages below the marker.

set -euo pipefail

# ──────────────────────────────────────────────────────────────────────────
# Wizard library — delightful, consistent UX. Identical across every wizard.
# ──────────────────────────────────────────────────────────────────────────

if [[ -t 1 ]] && command -v tput >/dev/null 2>&1 && [[ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]]; then
  BOLD=$(tput bold); DIM=$(tput dim); RESET=$(tput sgr0)
  BLUE=$(tput setaf 4); GREEN=$(tput setaf 2); YELLOW=$(tput setaf 3); RED=$(tput setaf 1)
else
  BOLD=""; DIM=""; RESET=""; BLUE=""; GREEN=""; YELLOW=""; RED=""
fi

# Author sets this at the top of the stages section.
TOTAL_STAGES=0

_STAGE_INDEX=0
ENV_FILE="${ENV_FILE:-.env}"
WRITTEN_ENV=()    # KEYs written to ENV_FILE this run
WRITTEN_SECRET=() # secret NAMEs set this run
SKIPPED=()        # things we couldn't do (e.g. gh missing)

# _clear — wipe the terminal so only the current step is on screen. No-op when
# output isn't a terminal, so piped logs stay readable.
_clear() {
  [[ -t 1 ]] || return 0
  if command -v tput >/dev/null 2>&1; then tput clear; else printf '\033[2J\033[3J\033[H'; fi
}

# banner "Title" — opening frame: what this wizard does.
banner() {
  _clear
  printf '\n%s%s  %s%s\n' "$BOLD" "$BLUE" "$1" "$RESET"
  printf '%s  %s stages%s\n\n' "$DIM" "$TOTAL_STAGES" "$RESET"
  printf '%s  You drive the browser; this wizard tells you exactly what to do and\n' "$DIM"
  printf '  captures the values you copy back. Stop any time with Ctrl-C and re-run\n'
  printf '  later — it remembers values already saved.%s\n' "$RESET"
  pause "Ready to start?"
}

# stage "Name" — clear the screen, then announce a stage and show progress.
# Clearing keeps only the current step on screen.
stage() {
  _clear
  _STAGE_INDEX=$((_STAGE_INDEX + 1))
  printf '\n%s%s▸ Stage %s/%s · %s%s\n' \
    "$BOLD" "$BLUE" "$_STAGE_INDEX" "$TOTAL_STAGES" "$1" "$RESET"
}

# say "..." — a plain instruction line.
say()  { printf '  %s\n' "$1"; }
# step "..." — a numbered-feeling action the human takes in the browser.
step() { printf '  %s•%s %s\n' "$BLUE" "$RESET" "$1"; }
note() { printf '  %s%s%s\n' "$DIM" "$1" "$RESET"; }
warn() { printf '  %s⚠ %s%s\n' "$YELLOW" "$1" "$RESET"; }

# open_url URL — open in the human's browser, cross-platform incl. WSL.
open_url() {
  local url="$1"
  printf '  %s↗ opening%s %s\n' "$GREEN" "$RESET" "$url"
  { if   command -v wslview     >/dev/null 2>&1; then wslview "$url"
    elif command -v explorer.exe >/dev/null 2>&1; then explorer.exe "$url"
    elif command -v xdg-open    >/dev/null 2>&1; then xdg-open "$url"
    elif command -v open        >/dev/null 2>&1; then open "$url"
    else warn "couldn't open a browser — visit it manually: $url"; fi
  } >/dev/null 2>&1 || warn "couldn't open a browser — visit it manually: $url"
}

# pause "msg" — wait for the human to confirm they've done the manual part.
pause() {
  printf '  %s%s%s ' "$DIM" "${1:-Press Enter to continue}" "$RESET"
  read -r _ || true
}

# confirm "question" — y/N gate; returns success on yes.
confirm() {
  local reply=""
  printf '  %s? %s [y/N] ' "$YELLOW" "$1"
  read -r reply || true
  [[ "$reply" =~ ^[Yy] ]]
}

# _existing KEY — current value of KEY in ENV_FILE, if any.
_existing() {
  [[ -f "$ENV_FILE" ]] || return 1
  local line; line=$(grep -E "^${1}=" "$ENV_FILE" | tail -n1) || return 1
  printf '%s' "${line#*=}"
}

# ask KEY "Prompt" — read a value into $KEY. Offers the existing .env value as
# a default on re-runs (Enter keeps it). Visible input (non-secret).
ask() {
  local key="$1" prompt="$2" current input
  current=$(_existing "$key" || true)
  if [[ -n "$current" ]]; then
    printf '  %s%s%s %s[Enter keeps current]%s ' "$BOLD" "$prompt" "$RESET" "$DIM" "$RESET"
  else
    printf '  %s%s%s ' "$BOLD" "$prompt" "$RESET"
  fi
  read -r input || true
  [[ -z "$input" && -n "$current" ]] && input="$current"
  printf -v "$key" '%s' "$input"
}

# ask_secret KEY "Prompt" — like ask, but input is hidden.
ask_secret() {
  local key="$1" prompt="$2" current input
  current=$(_existing "$key" || true)
  if [[ -n "$current" ]]; then
    printf '  %s%s%s %s[Enter keeps current]%s ' "$BOLD" "$prompt" "$RESET" "$DIM" "$RESET"
  else
    printf '  %s%s%s ' "$BOLD" "$prompt" "$RESET"
  fi
  read -rs input || true
  printf '\n'
  [[ -z "$input" && -n "$current" ]] && input="$current"
  printf -v "$key" '%s' "$input"
}

# write_env KEY VALUE — upsert KEY=VALUE into ENV_FILE (creates it; replaces
# any existing line). Idempotent.
write_env() {
  local key="$1" value="$2" tmp
  touch "$ENV_FILE"
  tmp=$(mktemp)
  grep -vE "^${key}=" "$ENV_FILE" > "$tmp" || true
  printf '%s=%s\n' "$key" "$value" >> "$tmp"
  mv "$tmp" "$ENV_FILE"
  WRITTEN_ENV+=("$key")
  printf '  %s✓ wrote%s %s → %s\n' "$GREEN" "$RESET" "$key" "$ENV_FILE"
}

# set_secret NAME VALUE — set a GitHub Actions repo secret via gh. Falls back
# to a warning (and records it) if gh is unavailable or unauthenticated.
set_secret() {
  local name="$1" value="$2"
  if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    if printf '%s' "$value" | gh secret set "$name" >/dev/null 2>&1; then
      WRITTEN_SECRET+=("$name")
      printf '  %s✓ set%s GitHub secret %s\n' "$GREEN" "$RESET" "$name"
      return
    fi
  fi
  SKIPPED+=("GitHub secret $name (set it manually: gh secret set $name)")
  warn "skipped GitHub secret $name — gh not ready; set it later"
}

# set_var NAME VALUE — set a GitHub Actions repo variable (non-secret).
set_var() {
  local name="$1" value="$2"
  if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    if gh variable set "$name" --body "$value" >/dev/null 2>&1; then
      printf '  %s✓ set%s GitHub variable %s\n' "$GREEN" "$RESET" "$name"
      return
    fi
  fi
  SKIPPED+=("GitHub variable $name")
  warn "skipped GitHub variable $name — gh not ready; set it later"
}

# finish — clear, then a closing summary of everything configured.
finish() {
  _clear
  printf '\n%s%s  ✓ Setup complete%s\n' "$BOLD" "$GREEN" "$RESET"
  (( ${#WRITTEN_ENV[@]} ))    && note "wrote ${#WRITTEN_ENV[@]} value(s) to $ENV_FILE: ${WRITTEN_ENV[*]}"
  (( ${#WRITTEN_SECRET[@]} )) && note "set ${#WRITTEN_SECRET[@]} GitHub secret(s): ${WRITTEN_SECRET[*]}"
  if (( ${#SKIPPED[@]} )); then
    printf '\n'; warn "still to do by hand:"
    for s in "${SKIPPED[@]}"; do note "  - $s"; done
  fi
  printf '\n'
}

# ──────────────────────────────────────────────────────────────────────────
# STAGES — one stage() per step the human takes.
# ──────────────────────────────────────────────────────────────────────────

cd "$(dirname "$0")/.."

# Nothing here lands in the repo: ids and paths persist under ~/.config,
# secrets go straight to the keychain / GitHub and are never written.
# The library defaults ENV_FILE to ./.env before this runs, so the
# assignment is unconditional (INFINITUS_SIGNING_ENV overrides).
ENV_FILE="${INFINITUS_SIGNING_ENV:-$HOME/.config/infinitus/signing.env}"
mkdir -p "$(dirname "$ENV_FILE")"
touch "$ENV_FILE" && chmod 600 "$ENV_FILE"

TEAM_ID=Q783W6B4FA          # the paid personal team ("Loc Truong")
NOTARY_PROFILE=infinitus    # notarytool keychain profile name

TOTAL_STAGES=6

banner "Infinitus signing setup"

# ── 1 ─────────────────────────────────────────────────────────────────────
stage "Mac — Developer ID Application certificate"
say "Gatekeeper trusts a Developer ID signature; make-app.sh picks the cert"
say "up automatically once it sits in the login keychain. Xcode creates it"
say "and keeps the private key here, so no CSR dance."
open -a Xcode 2>/dev/null || true
step "Xcode → Settings (⌘,) → Accounts → your Apple ID → team 'Loc Truong'."
step "Click 'Manage Certificates…' → '+' (bottom left) → 'Developer ID Application'."
note "Only the team's Account Holder sees that entry — that's you on a personal team."
note "Portal alternative: developer.apple.com → Certificates → + → Developer ID"
note "Application, with a CSR from Keychain Access → Certificate Assistant."
pause "Press Enter once the certificate shows in the list"
until security find-identity -v -p codesigning 2>/dev/null | grep -q "Developer ID Application"; do
  warn "no 'Developer ID Application' identity in the keychain yet"
  confirm "Try again? (No skips this check)" || break
done
security find-identity -v -p codesigning | grep "Developer ID Application" || true

# ── 2 ─────────────────────────────────────────────────────────────────────
stage "Mac — App Store Connect API key (notarization)"
say "notarytool authenticates with a TEAM key (an Individual key is refused)."
say "The .p8 downloads exactly once — keep it somewhere safe outside the repo."
open_url "https://appstoreconnect.apple.com/access/integrations/api"
step "Team Keys tab → '+' (Generate API Key) → name 'infinitus notary', access 'Developer'."
step "Copy the Issuer ID (top of the page) and the new key's KEY ID."
step "Click 'Download API Key' → AuthKey_<KEY ID>.p8 lands in ~/Downloads."
ask NOTARY_ISSUER_ID "Issuer ID (UUID):"
ask NOTARY_KEY_ID "Key ID (10 characters):"
ask NOTARY_KEY_PATH "Path to the .p8 file [~/Downloads/AuthKey_${NOTARY_KEY_ID}.p8]:"
NOTARY_KEY_PATH="${NOTARY_KEY_PATH:-$HOME/Downloads/AuthKey_${NOTARY_KEY_ID}.p8}"
NOTARY_KEY_PATH="${NOTARY_KEY_PATH/#\~/$HOME}"
if [[ -f "$NOTARY_KEY_PATH" ]]; then
  write_env NOTARY_ISSUER_ID "$NOTARY_ISSUER_ID"
  write_env NOTARY_KEY_ID "$NOTARY_KEY_ID"
  write_env NOTARY_KEY_PATH "$NOTARY_KEY_PATH"
  # Local notarization then needs only --keychain-profile.
  xcrun notarytool store-credentials "$NOTARY_PROFILE" \
    --key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID" \
    && printf '  %s✓ stored%s notarytool profile "%s" in the keychain\n' "$GREEN" "$RESET" "$NOTARY_PROFILE"
else
  warn "no file at $NOTARY_KEY_PATH — stages 3 and 4 need it"
  SKIPPED+=("notarytool store-credentials $NOTARY_PROFILE --key <p8> --key-id $NOTARY_KEY_ID --issuer $NOTARY_ISSUER_ID")
fi

# ── 3 ─────────────────────────────────────────────────────────────────────
stage "Mac — local proof: re-sign a copy → notarize → staple → Gatekeeper"
say "Same steps release.yml runs, on a COPY of the built Infinitus.app: the"
say "bundle in the repo and the running app are left alone (another session"
say "owns rebuilds), and nothing here needs a rebuild."
if [[ ! -d Infinitus.app ]]; then
  warn "no Infinitus.app in the repo — have it built first (./make-app.sh)"
  SKIPPED+=("local notarization proof (needs a built Infinitus.app)")
elif confirm "Notarize a copy of Infinitus.app now?"; then
  DEVID=$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' '/Developer ID Application/ {print $2; exit}')
  PROOF=$(mktemp -d)
  cp -R Infinitus.app "$PROOF/Infinitus.app"
  # Inside-out, as make-app.sh does: the helper, then the bundle.
  codesign --force --options runtime --timestamp --sign "$DEVID" \
    "$PROOF/Infinitus.app/Contents/MacOS/infinitusctl"
  codesign --force --options runtime --timestamp --sign "$DEVID" "$PROOF/Infinitus.app"
  ditto -c -k --keepParent "$PROOF/Infinitus.app" "$PROOF/notarize.zip"
  if xcrun notarytool submit "$PROOF/notarize.zip" --wait --keychain-profile "$NOTARY_PROFILE"; then
    xcrun stapler staple "$PROOF/Infinitus.app"
    spctl --assess --type execute -vv "$PROOF/Infinitus.app" \
      && printf '  %s✓ Gatekeeper accepts%s the notarized copy (%s)\n' "$GREEN" "$RESET" "$PROOF/Infinitus.app"
    note "The proof copy stays in $PROOF; the next release build gets the same treatment in CI."
  else
    warn "notarization did not pass — run: xcrun notarytool log <submission id> --keychain-profile $NOTARY_PROFILE"
    SKIPPED+=("notarization proof (see notarytool log)")
  fi
else
  SKIPPED+=("local notarization proof (RELEASING.md 'Local check')")
fi

# ── 4 ─────────────────────────────────────────────────────────────────────
stage "Mac — CI secrets (release.yml)"
say "The release workflow imports the cert from a .p12 and notarizes with the"
say "API key; with these five secrets set it stops shipping ad-hoc builds."
open -a "Keychain Access" 2>/dev/null || true
step "Keychain Access → login → My Certificates → right-click 'Developer ID Application: …' → Export…"
step "Format .p12, save as ~/Downloads/DeveloperID.p12, choose an export password."
ask P12_PATH "Path to the .p12 [~/Downloads/DeveloperID.p12]:"
P12_PATH="${P12_PATH:-$HOME/Downloads/DeveloperID.p12}"
P12_PATH="${P12_PATH/#\~/$HOME}"
ask_secret P12_PASSWORD "The .p12 export password:"
# A wrong password only surfaces in CI ("MAC verification failed during
# PKCS12 import", release v0.4.3's first run) — check it here first, with
# the same `security import` the release job runs (openssl 3 rejects the
# legacy ciphers Keychain Access exports with, even on the right password).
p12_opens() {
  local k; k="$(mktemp -d)/probe.keychain-db"
  security create-keychain -p "" "$k" >/dev/null 2>&1 || return 1
  security import "$1" -k "$k" -P "$2" -T /usr/bin/codesign >/dev/null 2>&1
  local rc=$?
  security delete-keychain "$k" >/dev/null 2>&1
  return $rc
}
until [[ ! -f "$P12_PATH" ]] || p12_opens "$P12_PATH" "$P12_PASSWORD"; do
  warn "that password does not open $P12_PATH"
  ask_secret P12_PASSWORD "The .p12 export password (again):"
done
if [[ -f "$P12_PATH" && -f "${NOTARY_KEY_PATH:-/nonexistent}" ]]; then
  set_secret DEVELOPER_ID_P12_BASE64 "$(base64 -i "$P12_PATH")"
  set_secret DEVELOPER_ID_P12_PASSWORD "$P12_PASSWORD"
  set_secret NOTARY_KEY_ID "$NOTARY_KEY_ID"
  set_secret NOTARY_ISSUER_ID "$NOTARY_ISSUER_ID"
  set_secret NOTARY_KEY_BASE64 "$(base64 -i "$NOTARY_KEY_PATH")"
  note "next v* tag builds notarized; then drop --no-quarantine from README, site and cask."
else
  warn "missing $P12_PATH or the .p8 — see docs/RELEASING.md for the five secrets"
  SKIPPED+=("GitHub secrets DEVELOPER_ID_P12_BASE64, DEVELOPER_ID_P12_PASSWORD, NOTARY_KEY_ID, NOTARY_ISSUER_ID, NOTARY_KEY_BASE64")
fi

# ── 5 ─────────────────────────────────────────────────────────────────────
stage "Phone — device build on the team"
say "ios/project.yml carries DEVELOPMENT_TEAM $TEAM_ID; the first build with"
say "-allowProvisioningUpdates registers the bundle ids and mints one profile"
say "per target (app, widgets, share extension). Xcode must be signed in to"
say "the team (Settings → Accounts) — nothing to click otherwise."
xcrun devicectl list devices 2>/dev/null | grep -E "physical|Identifier" || true
ask DEVICE_UDID "Phone UDID to install on (blank = build only):"
if [[ -n "$DEVICE_UDID" ]]; then write_env DEVICE_UDID "$DEVICE_UDID"; fi
if confirm "Build the phone app now?"; then
  # A named device as the destination is what registers a new phone on
  # the team; generic/platform=iOS only signs for devices already there.
  DEST="generic/platform=iOS"
  [[ -n "$DEVICE_UDID" ]] && DEST="id=$DEVICE_UDID"
  (cd ios && xcodegen generate >/dev/null && xcodebuild -quiet \
      -project InfinitusMobile.xcodeproj -scheme InfinitusMobile \
      -destination "$DEST" -derivedDataPath build \
      -allowProvisioningUpdates build)
  APP="ios/build/Build/Products/Debug-iphoneos/InfinitusMobile.app"
  codesign -dvv "$APP" 2>&1 | grep TeamIdentifier || warn "the build is not team-signed"
  if [[ -n "$DEVICE_UDID" ]]; then
    xcrun devicectl device install app --device "$DEVICE_UDID" "$APP" \
      && printf '  %s✓ installed%s on %s\n' "$GREEN" "$RESET" "$DEVICE_UDID"
  fi
else
  SKIPPED+=("phone device build (cd ios && xcodebuild … -allowProvisioningUpdates build)")
fi

# ── 6 ─────────────────────────────────────────────────────────────────────
stage "Push — APNs key for Live Activity updates (#70)"
say "The Mac pushes Live Activity updates with an APNs auth key. This is a"
warn "DIFFERENT .p8 from stage 2's App Store Connect key — don't reuse that one."
open_url "https://developer.apple.com/account/resources/authkeys/add"
step "Key name 'infinitus apns' → tick 'Apple Push Notifications service (APNs)' → Continue → Register."
step "Note the KEY ID, click Download (once) → AuthKey_<KEY ID>.p8."
ask APNS_KEY_ID "APNs Key ID (10 characters, blank to skip):"
if [[ -n "$APNS_KEY_ID" ]]; then
  write_env APNS_KEY_ID "$APNS_KEY_ID"
  step "Open the .p8 in a text editor and copy its whole contents to the clipboard."
  step "Infinitus (menu bar) → Settings → Devices → 'Phone lock screen' → Team ID '$TEAM_ID', Key ID '$APNS_KEY_ID' → 'Paste .p8 from clipboard'."
  note "The key lives in the Mac keychain only (run.infinitus.apns); shown masked."
  pause "Press Enter once the row says 'key in the keychain'"
  security find-generic-password -s run.infinitus.apns -a "$APNS_KEY_ID" >/dev/null 2>&1 \
    && printf '  %s✓ found%s the APNs key in the keychain\n' "$GREEN" "$RESET" \
    || warn "no keychain item for key $APNS_KEY_ID yet — paste it in Settings › Devices"
else
  SKIPPED+=("APNs key → Settings › Devices (issue #70)")
fi

finish
