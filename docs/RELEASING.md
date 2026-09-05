# Releasing Infinitus

A `v*` tag push runs `.github/workflows/release.yml`: build on the
macOS 26 runner, zip, GitHub release, tap cask bump. Nightly does the same
from `main` daily.

## Signing today

Ad-hoc in CI, Apple Development locally (Gatekeeper on another Mac
needs `--no-quarantine` or right-click → Open). The Developer ID
pipeline was proven end-to-end on 2026-09-01 under the company team,
then unsigned the same day. The personal paid team (`Q783W6B4FA`,
2026-09-05) redoes it: `tools/signing-wizard.sh` walks every step
below — cert, API key, local notarization proof, the five CI secrets,
the phone's first team build, the APNs key for #70 — and re-runs safely.

## Getting a Developer ID

- Only a team's **Account Holder** can create Developer ID certificates:
  Xcode → Settings → Accounts → the team → Manage Certificates → "+" →
  Developer ID Application (the private key stays in the login
  keychain). Under an organization's team, every Gatekeeper prompt names
  the organization as the signer and notarization runs under its account.

Export the cert + private key from Keychain Access as a `.p12`, and create
an App Store Connect API key (Users and Access → Integrations → **Team**
keys, role Developer; individual keys are refused) for notarization.
`xcrun notarytool store-credentials infinitus --key … --key-id … --issuer …`
makes the local loop `notarytool submit --keychain-profile infinitus`.

`make-app.sh` signs inside-out: the bundled `infinitusctl` first, then
the bundle — a bundle-only codesign leaves the helper on its ad-hoc
linker signature, which notarization rejects.

## Wiring it into CI

Repository secrets; the workflow's Developer ID steps run only when
`DEVELOPER_ID_P12_BASE64` is set, otherwise the ad-hoc path is unchanged.

| Secret | Value |
|---|---|
| `DEVELOPER_ID_P12_BASE64` | `base64 -i DeveloperID.p12` |
| `DEVELOPER_ID_P12_PASSWORD` | the .p12 export password |
| `NOTARY_KEY_ID` | API key id (e.g. `ABC123DEFG`) |
| `NOTARY_ISSUER_ID` | issuer UUID from the same page |
| `NOTARY_KEY_BASE64` | `base64 -i AuthKey_ABC123DEFG.p8` |

The steps: import the cert into a throwaway keychain → `make-app.sh`
signs with `--options runtime --timestamp` → `notarytool submit --wait` →
`stapler staple Infinitus.app` → zip. Stapling attaches to the app, so the
released zip is built after it. Once a notarized release exists, drop the
`--no-quarantine` wording from the README and the cask.

Local check of a Developer ID build: the wizard's stage 3 re-signs a
copy of `Infinitus.app` in a temp dir, notarizes, staples and runs
`spctl --assess` on it — no rebuild, the repo bundle untouched.

## Phone

`ios/project.yml` carries `DEVELOPMENT_TEAM` and automatic signing, so a
plain `xcodebuild -destination 'generic/platform=iOS'` is a team-signed
device build; add `-allowProvisioningUpdates` once so Xcode registers
the three bundle ids and mints their profiles (the wizard's stage 5
does, and installs with `devicectl`). CI's simulator job still passes
`CODE_SIGNING_ALLOWED=NO` on the command line. TestFlight is not wired:
it needs an App Store Connect app record and an archive/export, which
flips `aps-environment` to production.
