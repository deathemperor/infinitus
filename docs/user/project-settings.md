# Settings and project overrides

Infinitus separates **device preferences** (saved locally per browser/device, like Appearance and Confirmations) from **server settings** (stored on each environment, like Threads, Worktrees, and Source control).

## Scope and inheritance

Use the **"Applying settings for …"** selector at the top of Settings (web/desktop) or the header filter (mobile) to choose which **environment(s)** and **project** you are editing:

- **All environments**: Bulk-edits every currently connected environment (offline environments keep their values). Controls show **Mixed** where environments disagree.
- **Project scope**: Creates a project override for that setting without changing environment defaults. Settings that cannot be overridden appear read-only.
- **Inheritance order**: `Project override` → `Environment setting` → `t3.json` in the repo → `Built-in default`. Leave a setting on **Inherit** to defer to the next tier.
- Click the **layers icon** beside a server setting to inspect its inheritance chain, jump to overriding projects, or **Reset all** back to the environment default.
- **Per-project providers**: With a project selected in **Settings → Providers**, toggling a provider enables or disables it for that project only (in either direction). Running turns finish; no new turns start on a disabled provider.

## Pin and archive projects

- **Pin**: Pinned projects sort first in project pickers, the command palette, the sidebar filter, and mobile (`mod+shift+p` on a highlighted row, or **Settings → Projects**).
- **Archive**: Archive finished projects in **Settings → Projects** (mobile: **Settings → Projects → Organize**). Archived projects leave pickers while keeping their threads, settings, and files; unarchive anytime from Settings.
- Pinning or archiving a project that exists on multiple machines requires all of those machines to be connected.

## Project icons and multi-repo projects

- **Icons**: In **Settings → Projects**, set an icon, emoji, monogram, or image (applies across checkouts). Without one, Infinitus generates a two-character monogram (or single CJK character) from the project name.
- **Multiple repositories**: See [Projects with several repositories](./multi-repo-projects.md).

## Worktree settings

Configure worktrees in **Settings → Worktrees** (environment default or project override):

- **Branch naming**: Choose a static prefix (default `t3/`), model-selected semantic prefix (`feat/`, `fix/`), or custom instructions. Falls back to the temporary branch name if generation fails or collides.
- **Submodules** (under Advanced): Defaults to recursive checkout; set to **Top level only** or **Skip** (or `"worktreeSubmodules"` in `t3.json`) for repos with heavy nested submodules.
- **Sparse checkout**: Set `"worktreeSparsePatternsPath"` in `t3.json` to a repo-relative file of Git sparse-checkout patterns (non-cone syntax; requires Git 2.35+; enables `extensions.worktreeConfig`). Set Submodules to **Skip** if you don't want submodules initialized under excluded paths.
- **Worktree location** (per machine): Set an absolute path (e.g. `D:\worktrees` or `~/worktrees`) to store new worktrees elsewhere. Existing worktrees stay where they are; cleanup covers both folders.
- **Fast worktree checkout (macOS beta)**: Enable **Settings → Labs → Fast worktree checkout** (Git 2.42+) to clone new worktrees via APFS copy-on-write from a local cache. Falls back to normal checkout for cross-drive paths, sparse checkouts, or Git LFS/filter repos.

### Storage cleanup

Enable automatic cleanup in **Settings → Worktrees → Cleanup** (off by default; runs on startup, on change, and hourly). Projects can set **Automatic worktree cleanup** to **Inherit**, **Off**, or **Custom**.

<<<<<<< HEAD
Under **Destination**, choose where runs go. **New thread each run** keeps every
run separate. The two one-thread choices start a thread on the first run and post
later runs there: one continues the same conversation, the other starts each run
in a fresh session that doesn't see earlier runs, so the thread stays readable
without the agent's context growing. To move a one-thread task, pick another
thread in its project under **Destination**. Moving such a task to another
project starts a new thread there on its next run.

Deleting a thread also deletes tasks that post into that thread. Tasks that start
a new thread on each run survive deletion of their previous threads.

You can edit, pause, resume, run immediately, or delete a task from the list.
Webhook tasks only run when their URL is called, so they can't be run
immediately.
Leaving an edited form asks before discarding unsaved changes.

## Webhook automations

In **Settings → Scheduled tasks**, choose **On webhook**
as a task's schedule to run it whenever another service calls its URL, such as
GitHub on a new pull request or a CI job that failed. A public URL needs a
[Infinitus Connect](remote-access.md) managed tunnel; after you save the task, copy
its URL from the editor. Without one, the editor shows only the URL's path.
**Rotate** replaces the URL and the old one stops working.

The prompt decides what the agent sees. Placeholders pull values out of the
request: `{{body.path}}` for a JSON or form field, `{{headers.name}}`,
`{{query.name}}`, `{{body}}` for the raw body, and `{{request}}` for everything.
For example, `Review this PR: {{body.pull_request.html_url}}` sends only the
pull request link. A placeholder with no value is left empty.

Each value reaches the agent wrapped in `<webhook-data-…>` tags and marked as
untrusted request data. This helps the agent tell it apart from your
instructions, but it doesn't guarantee the agent ignores what the text says.
Inside a value, every `$`, other currency sign and `@`, and a `/` that starts
a lone word, gets an invisible character after it, so mentions like `$skill`,
`@file` and `/command` don't act. Text copied from a value, such as an email
address or a command, carries that character too. Without a signature, anyone
with the URL can start a run with any content. A signature only proves which
service sent the request: a GitHub payload still carries text written by any
GitHub user.

For GitHub, turn on **Require signature**, keep the header
`x-hub-signature-256`, hex encoding and the `sha256=` prefix, and enter the
same secret in the repository's webhook settings with content type
`application/json`. Requests without a valid signature are rejected. Set this
up on desktop or web; mobile keeps an existing signature check but can't turn
one on.

To run only for some requests, add **Filters**. Each one tests a value named
like a placeholder, without the braces, such as `headers.x-github-event` equals
`pull_request` or `body.action` is one of `opened, reopened`. A task runs only
when every filter matches; other requests are answered normally, logged as
**Filtered** with the first filter that failed, and start nothing. Values
compare as text, and a value that is an object or a list only passes
**exists**. Separate **is one of** values with commas; a value can't contain
a comma or start or end with a space.

To suppress repeated deliveries, set a **Duplicate request key** template, such as
`{{headers.delivery-id}}`. The same key is ignored for seven days per task.
To combine a burst, set a **Coalesce key**, such as `{{body.id}}`, and a window
of 10–3600 seconds (120 by default). One run uses the latest body, headers,
and query when the window from the first delivery closes; later requests
do not extend it. Pending windows survive a server restart. Keys must contain
request placeholders; if any placeholder is missing, or the render is empty,
that key's rule is skipped. Clear the templates to turn dedupe off.

Duplicate and coalesced log entries share a limit of 10 per task per minute.
Additional deliveries are accepted without a log entry, and coalesced deliveries
always replace the persisted payload. Coalesced updates count toward a separate
60-per-minute validation limit; exceeding it receives HTTP 429.

On desktop and web, pick **Deliveries** from a task's menu to see recent
requests and the prompt each one produced.

If the environment is offline, the sender gets an error and nothing runs;
redeliver from the sender, such as GitHub's **Recent Deliveries**, once it is
back. To have Infinitus Connect keep requests instead, turn on **Hold webhooks while
offline** in **Settings → Sharing & access**. Infinitus Connect then stores requests to an
Infinitus Connect URL for up to 24 hours and delivers them when the environment
returns. Leave it off if you don't want request bodies stored outside your
machine. To skip requests that waited too long, set **Skip requests older
than** on the task.

## Defaults and inheritance

Threads contains the model and workspace for new threads. Browser controls agent browser
access. Source control & issues contains automatic pull, the default pull request merge method and text
generation. The same rows edit environment defaults or project overrides depending on the
project crumb.

The Projects category, under Code, holds the project's name, icon, actions,
checkouts and removal. Actions belong to a project: editing them creates the project's own list
on each selected environment, and reset returns to the environment's shared list. A project's
`infinitus.json` actions can be imported there. When a project has several checkouts on one environment,
choose one in the scope line at the top to see or change only that checkout's settings.

Settings a repository can also declare in `infinitus.json`, such as the workspace for new threads,
resolve in one order: a project override, then the environment setting, then `infinitus.json`, then the
built-in default. Leave a setting on **Inherit** to let the next tier decide.
Browser access changes apply when an agent session next starts.

New worktrees initialize git submodules recursively. If that step is slow because the repository
declares many nested submodules, set **Submodules** in **Settings → Worktrees** under Advanced (with the project
selected to override it there) to **Top level only** to stop at the ones the repository declares
itself, or **Skip** to leave them for a setup script. It resolves in the same order as the
workspace default: a `"worktreeSubmodules"` value in the `infinitus.json` of the branch being checked out
applies when the project and environment are both on **Inherit**.

New worktrees check out every file. For a large repository, set `"worktreeSparsePatternsPath"` in
`t3.json` to a repository-relative file of git sparse-checkout patterns in non-cone syntax. New
worktrees then check out only the matching files, before any other file is written. Both files are
read from the branch being checked out, so the patterns can leave out `t3.json` and `.gitmodules`.
If the pattern file is missing, creating the worktree fails instead of checking out everything.
Submodules still follow **Submodules** above, also under excluded paths; set it to **Skip** to leave
them empty. The first sparse worktree turns on Git's `extensions.worktreeConfig` for the repository.
This needs Git 2.35 or newer.

## Worktree location

New worktrees go in the `worktrees` folder of the Infinitus home directory. To put them somewhere else,
such as another drive, set **Settings → Worktrees → Worktree location** to an absolute path like
`D:\worktrees` or `~/worktrees`. The setting is per machine. Existing worktrees stay where they
are, and cleanup covers both the default folder and the custom one.

## Worktree limit

A server keeps at most 25 worktrees across its threads. Past that, sending in **New worktree**
mode is refused before the thread is created, and the message names the oldest archived
threads still holding one: deleting a thread frees its worktree. Change the ceiling in
**Settings → General → Worktree limit**; 0 lifts it. Threads in the project checkout never count.

## Fast worktree checkout on macOS

Fast worktree checkout is a beta. Turn it on for each Mac in **Settings → Labs → Fast worktree
checkout**. Infinitus then keeps a few recent checkouts of each repository in the `caches` folder of
the Infinitus home directory. A new worktree is cloned from one of them with APFS copy-on-write, which is
about twice as fast as writing every file and makes the first `git status` in it fast as well.
Turning it off deletes the cache.

The first worktree of a repository uses Git's normal checkout and fills the cache. It needs Git 2.42
or newer. Git's normal checkout is also used for worktrees on a different drive from the Infinitus home
directory, sparse checkouts, repositories whose attributes use filters such as Git LFS, and
repositories whose checkout settings changed.

## Storage cleanup

Open **Settings → Worktrees → Cleanup** to enable automatic cleanup on one machine or all connected
environments. Policies are off by default and run on the server at startup, when changed, and
hourly. Offline machines keep their existing policies.

Select a project to set **Automatic worktree cleanup** to **Inherit**, **Off**, or **Custom**.
Inherit follows each machine's rules; Off keeps that project's worktrees until you remove them
manually. Custom applies separate worktree rules to the selected project or checkout. Browser
captures and log retention remain machine-wide.

Worktrees can be removed after a chosen number of inactive days, after a thread settles, after
merging, or when they have no commits beyond the default branch and their thread is settled or
archived. Set settled retention to 0 days to remove a worktree at the next cleanup after
settlement. In repositories without remotes,
unchanged-worktree cleanup compares against the branch checked out in the project workspace;
if that checkout has a detached HEAD, the worktree is kept. Only Infinitus-managed worktrees are eligible.
Active sessions and shared worktrees prevent removal. **Keep worktrees with local changes** defaults
to **Uncommitted changes**, which protects tracked edits and untracked files but deletes ignored
files such as `.env` and build output. **Any local files** also protects ignored files other than
`node_modules`. **Edited tracked files** protects only tracked edits and allows untracked and
ignored files to be deleted. Branches and thread history stay; starting another turn recreates the checkout.
Merge cleanup requires a merged pull request whose commits are included in the remote default
branch. A squash or rebase merge on GitHub also counts when the pull request targeted the default
branch and the worktree is still at the pull request's last commit.

Enable **Delete worktrees with deleted threads** to remove safe worktrees after their last
thread is deleted, including archived threads and worktrees left by earlier deletions. The
server waits for sessions and terminals to stop and retries skipped worktrees after restart.
Existing prompts for deleting a worktree manually remain available when this policy is off.

Choose **Delete now** to run the enabled rules immediately. The latest results show which
worktrees were removed or kept and why, plus any failures.
Results also list folders in the worktree folder that no thread uses, with their sizes; cleanup never removes them, so remove them manually if you want.

The inactive and settled retention periods also apply to the folders of
[threads without a project](./thread-sidebar.md#start-without-a-project). Those folders are not
Git repositories, so their files are deleted with them and cannot be recovered; the thread stays,
and its next turn starts in a new, empty folder. A folder is kept when it has a Git repository
anywhere inside it or when its thread has an enabled scheduled task. Every file in such a folder
counts as untracked, so only **Edited tracked files** removes a folder that holds anything other
than `node_modules`; the other two rules remove only empty folders. Folders that no thread uses
are listed here too.

Browser captures and rotated logs have separate retention periods. Expired capture links stop
working. Current logs, message attachments, and browser profiles are kept.

## Project icons

Select the project and open Project to choose an icon, emoji, monogram, or image. The choice applies to
every checkout in the project group and appears on connected clients. Choose **Automatic** to let
Infinitus detect an icon again.

Choose **Monogram** in the icon picker to set one or two letters or numbers and a color.

When no image is found, web and desktop show a two-character monogram with a color
from the icon palette, derived from the saved project name. For example, `Nebula` becomes `NA`,
`Silver Orchard` becomes `SO`, and `M7 Forge` becomes `M7`.
=======
- **Triggers**: Inactive days, days after settlement (`0` = next cleanup), merged PRs (including GitHub squash/rebase merges into the default branch), or settled/archived threads with no commits beyond the default branch.
- **Safety**: Active sessions and shared worktrees are never removed. **Keep worktrees with local changes** defaults to **Uncommitted changes** (protects tracked edits and untracked files; removes ignored files like `.env`/build output). Choose **Any local files** (also protects ignored files except `node_modules`) or **Edited tracked files** (protects tracked edits only).
- **Delete with deleted threads**: Enable **Delete worktrees with deleted threads** to automatically clean up safe worktrees once their last thread is deleted.
- **Scratch folders**: Inactive and settled rules also apply to [no-project scratch folders](./thread-sidebar.md#start-without-a-project) (skipped if they contain a Git repo or enabled scheduled task). Because scratch files aren't in Git, deleted files cannot be recovered.
- **Manual run**: Click **Delete now** to run rules immediately and inspect what was removed, kept, or orphaned (untracked folders are listed but never auto-deleted).
- **Captures and logs**: Browser captures and rotated logs have separate machine-wide retention periods.
>>>>>>> upstream-sync-986826178c-upstream-renamed

## Keep the default branch current

Enable **Settings → Source control & issues → Automatically pull** to fast-forward clean default-branch checkouts from their configured upstream. Skips checkouts with local changes, untracked files, local commits, other branches, or no upstream.

## Scheduled tasks and webhooks

Create and manage scheduled tasks in **Settings → Scheduled tasks** (web, desktop, and mobile).

- **Schedules**: Recurring fixed-time schedules use the target environment's time zone. **Once** uses your local time zone (runs on reconnect if offline).
- **Destination**: Choose **New thread each run**, **One thread (continue conversation)**, or **One thread (fresh session each run)**. Deleting a target thread deletes tasks bound to it; archiving a target thread causes runs to fail (settle it instead).
- **Controls**: Edit, pause, resume, run now (except webhook tasks), or delete from the list.

### Webhook automations

Choose **On webhook** as a task's schedule to trigger runs from external services (e.g., GitHub PR or CI events). A public URL requires a [Infinitus Connect](./remote-access.md) tunnel; click **Rotate** to invalidate and replace the URL.

- **Prompt placeholders**: Insert `{{body.path}}`, `{{headers.name}}`, `{{query.name}}`, `{{body}}`, or `{{request}}`. Missing values render empty.
- **Untrusted input protection**: Placeholder values are wrapped in `<webhook-data-…>` tags, and `$`/`@`/leading `/` tokens are neutralized so untrusted payloads can't invoke skills or commands.
- **Signatures** (web/desktop setup): Enable **Require signature** to verify HMAC signatures (for GitHub, keep `x-hub-signature-256`, hex, and `sha256=` prefix with the same secret and `application/json`).
- **Filters**: Add conditions (using paths without braces, e.g. `headers.x-github-event` equals `pull_request`, or `body.action` is one of `opened, reopened`). All filters must match; non-matching requests are logged as **Filtered**.
- **Deduplication & coalescing**: Set a **Duplicate request key** (e.g. `{{headers.delivery-id}}`; ignores repeats for 7 days) or a **Coalesce key** with a 10–3600s window (default 120s; runs once with the latest payload when the window closes). Coalesced updates are rate-limited to 60/min (`HTTP 429`).
- **Offline delivery**: By default, offline environments return an error. Enable **Settings → Sharing & access → Hold webhooks while offline** to buffer Infinitus Connect webhooks for up to 24 hours, and optionally set **Skip requests older than** on the task.
- **Debugging**: Open **Deliveries** from a task's menu (web/desktop) to inspect recent payloads and rendered prompts.
