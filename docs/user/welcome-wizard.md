# Welcome wizard

Infinitus shows a setup flow when you open a new installation or connect to the
hosted app for the first time. Existing workspaces skip this flow.

## Connect your computers

Select one or more computers to set up. If you opened Infinitus directly from a
server or the desktop app, that computer is already connected and selected.
It is identified by its name, which may differ from the device running your
browser.

You can add more computers before continuing:

- **T3 Connect** connects computers that are signed in to your account. On a
  Mac, sign in from the desktop app's **Settings → Connections** and keep the
  app running; on a Linux server, run the unpacked archive's `./t3 connect`
  and then `./t3 serve`, or install the [background service](./background-service.md).
- **Add a computer** connects directly to a server on your network or tailnet.
  From a desktop app, create the pairing link in **Settings → Connections**
  with **Network access** on. From a Linux server, start it with
  `./t3 serve --host <address>` (or `--tailscale-serve`), then `./t3 pair`
  (or `./t3 pair --tailscale`) prints the link to paste. See
  [Remote access](./remote-access.md).

Saved computers and computers discovered through T3 Connect are selected by
default. Uncheck any you do not want to set up; this does not disconnect them.
Continue when your selected computers are connected. Setup checks
agents across the selected computers, then offers project import grouped by computer.

If Infinitus cannot confirm the workspace during startup, the setup flow shows
**Still connecting** instead of opening the app. Select **Reload** to try again.

If Infinitus cannot read your saved settings, it shows **Could not read settings**.
Select **Retry** after storage becomes available. Setup does not replace
unreadable settings with defaults.

## Check your agents

Infinitus checks each selected computer for Claude Code and Codex. If an agent is
not installed or signed in, select its action to open a terminal with the
correct command ready to run. Install uses the vendor's standalone installer,
which does not need Node or npm and keeps **Update now** working in Settings.
Other providers can be enabled in Settings.

The setup terminal uses the home directory and environment configured for the
selected provider instance. Sensitive values remain redacted in Settings and
terminal metadata while the terminal process can use them.

## Import your projects

Infinitus finds directories that Claude Code or Codex has used. Git repositories
are listed first, newest activity on top. When the remote is on GitHub, the
group shows the repository as `owner/name`. Clones with the same remote share
one group. Directories that are not git repositories sit under "Other folders".

The default selection includes git repositories active within the last 30 days
with at least three conversations. Use the checkboxes, or "Select all" and
"Select none", to change the selection. Linked git worktrees, Codex scratch
directories under `Documents/Codex`, and anything under `Downloads` are not
offered.

A large or malformed history can reach the scan limit. Infinitus keeps the
projects it found and warns when projects or conversations may be missing.

Imported projects include Codex and Claude conversations active within the last
30 days. You can continue those conversations in Infinitus.

Conversation import is best effort. Infinitus keeps the first user prompt and the
newest remaining visible user and assistant messages, with 200 messages total.
It omits tool activity and attachments. For Codex, it omits generated setup
context only when a canonical user event and a valid shared turn ID identify the
same user turn. Ambiguous legacy or response-only context stays in the imported
conversation so Infinitus does not remove user text. It reads one conversation at
a time and skips files larger than 16 MiB. It ignores malformed records and skips
unreadable or unparseable conversations.

Each import attempt reads up to 100 conversation files and 64 MiB per project,
with up to 100,000 input records. Run import again to continue a large batch.
Completed conversations are not imported again. You can continue without the
remaining history.

You can continue without configuring agents or importing projects, or return to an earlier step
using the setup progress bar. Navigation pauses while an import is running.
