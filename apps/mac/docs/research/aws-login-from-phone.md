# AWS sign-in from the phone (2026-09-03)

User ask: "sessions on this machine often need `aws login` for SSO
authorization; identify those sessions, let me log in on mobile, the
session takes the key and continues."

## What the CLI offers (aws-cli 2.36)
- `aws login --remote --profile X`: no local callback server; prints
  `Please visit the following URL:` + URL, then prompts
  `Enter the authorization code displayed in your browser:` and reads
  it from stdin. Made for SSH hosts — i.e. exactly "sign in elsewhere".
  Success line: `Updated profile X to use arn:… credentials.`
- `aws sso login --use-device-code --no-browser --profile X`: prints URL
  + `Then enter the code:` + `XXXX-XXXX`; polls the token endpoint and
  finishes by itself once the user approves on any device.
- Profile kind decides the flow (`~/.aws/config`): `sso_session` /
  `sso_start_url` → device code; `login_session` / `credential_process`
  → `--remote`.

- Plain `aws login --profile X` (probed 2026-09-03): prints the
  authorize URL even when the browser can't open, with
  `redirect_uri=http://127.0.0.1:<port>/oauth/callback`. With
  `BROWSER=/usr/bin/true` no Mac browser opens. The phone's web view
  intercepts the redirect to 127.0.0.1 and posts it to the Mac
  (`/aws-login/callback`), which GETs it against the CLI's listener —
  the **relay** flow, no code at all. `AwsLogin.isValidCallback` only
  lets http://127.0.0.1:<that port>/oauth/callback?code=… through.

## How sessions surface the need
Tool results carry `aws: [ERROR]: Your session has expired. Please
reauthenticate using 'aws login'.` and the cred broker's
`[aws-cred-broker] could not refresh credentials for 'papaya-login' …
Fix: aws login --profile papaya-login`. `AwsLogin.profile(in:)` reads
the profile off that; `SessionProgress.awsLoginProfile` scans the
newest 12 tail entries so the need clears once the session moves on.

## Pieces
- InfinitusCore/AwsLogin.swift — detection, flow choice, prompt
  parsing, wire types (`Item`, `State`, `StartRequest`, `CodeRequest`,
  `Reply`), paths `/aws-login/start`, `/aws-login/code`.
- Infinitus/AwsLoginRunner.swift — one CLI process per profile under
  `script -q /dev/null` (a pty, so the prompt reads stdin like a
  terminal); output parsed for URL / code / success only; 10-minute
  cap; code written to stdin and nowhere else.
- AppModel: `awsLogins` (needs × runner state) → snapshot
  `awsLogins`, popup `AwsLoginLine`, mirror routes, ctl verbs; on
  `.done` the session is nudged through `SessionInput.deliver`.
- Phone (main session): session screen banner → Start → open URL →
  code field → POST.

## Not done / watch
- The "no session asked" case: a login started by hand shows while it
  runs, then drops.
- If the `--remote` prompt ever stops reading from the pty, fall back
  to `expect`-style handling; the runner already has the pty.
- Infinitus never touches `~/.aws/login` / `~/.aws/sso` caches.
