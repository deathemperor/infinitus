# Messages and context

Use the composer to send prompts, attach files, reference threads or pull requests, invoke skills, and steer or queue follow-ups.

## Limits and large pastes

- **Message length**: Up to 120,000 characters.
- **Large pastes**: Pasting 32 KiB+ of text (or any paste that would exceed the message limit) turns it into a text-file attachment so it doesn't bloat the prompt. Use `Cmd+Shift+V` (Apple) or `Ctrl+Shift+V` (Windows/Linux) to paste inline instead.

## Formatting

The composer renders Markdown live as you type and reveals raw markers when your cursor enters styled text. The agent receives the exact Markdown you typed.

- Disable live styling in **Settings → Chat → Rich text composer**.
- Standard Markdown triggers (`- `, `1. `, `- [ ] `, `> `, `# `, `---`, and ` ``` ` + Enter) create lists, quotes, headings, rules, and code blocks.
- In lists/quotes, `Shift+Enter` continues (or exits on an empty line), and `Tab` / `Shift+Tab` indents or outdents.
- In code blocks, `Enter` keeps indentation, `Tab` / `Shift+Tab` indents selected lines, and closing ` ``` ` + Enter (or two blank lines) exits the block.

## Attach files

Attach up to **100 files** per message:

- **Images**: Up to 10 MiB each, 80 MiB total per message. HEIC/HEIF photos are converted to JPEG, and oversized photos are resized automatically.
- **Other files (including videos)**: Up to 50 MiB each (subject to environment limits). Video attachments pass a file path; only [Antigravity](./providers-antigravity.md#skills-and-attachments) sends supported videos natively to Gemini models.

<<<<<<< HEAD
You can drag or paste images into the web or desktop composer. HEIC and HEIF
photos are converted to JPEG there and when selected from the mobile photo
library; photos over the image limit are also resized to fit. On mobile, you can
also send files to Infinitus through another app's system share sheet, into a new task or an existing thread.
Closing the new task without sending or choosing a thread discards what you shared.
On Android, you can also drag images from another app into the message input
in split screen.
=======
Files upload to the environment's machine as soon as you attach them, and all uploads must finish before sending. Provider and model limits still apply.

- **Web and desktop**: Drag, paste, or pick files. Reloading before an upload finishes requires re-attaching.
- **Mobile**: Pick files, share into Infinitus via the system share sheet, or drag images in Android split screen.
>>>>>>> upstream-sync-986826178c-upstream-renamed

See [images and videos](#images-and-videos-in-messages) for previewing and saving media.

## Send while the agent is working

<<<<<<< HEAD
On web and desktop, choose **Settings → Chat → Follow-up behavior** to queue
new messages for a later turn or steer the running turn. A steer is sent at the
turn's next step: once its next tool call finishes, or when the turn ends if that
comes first. Until then it waits above the composer marked "at next step", where
you can still edit it, remove it, or press its Send now button to send it right
away. The setting applies to this client; already queued messages keep their
place. Queued messages are saved on the server and can be edited or removed
before they send.
When Enter sends, `Cmd+Enter` on macOS or `Ctrl+Enter` on Windows and Linux uses
the opposite action: it steers when your default is Queue and queues when your
default is Steer.
If your **Send shortcut** requires `Cmd+Enter` or `Ctrl+Enter`, that shortcut uses
your default follow-up behavior; add **Shift** to use the opposite action. This
applies only to multiline messages when you choose the multiline send option.
=======
Choose your default follow-up behavior in **Settings → Chat → Follow-up behavior** (per client):
>>>>>>> upstream-sync-986826178c-upstream-renamed

- **Queue**: Holds the message on the server for the next turn.
- **Steer**: Injects the message into the running turn (when supported by the agent).

Shortcuts while a turn is running:

- **Opposite action**: `Cmd+Enter` (macOS) or `Ctrl+Enter` (Windows/Linux) uses the non-default action. If your send shortcut already requires `Cmd/Ctrl+Enter`, add `Shift`. On mobile, long-press the send button or use `Cmd/Ctrl+Return` on a hardware keyboard.
- **Steer oldest queued message**: `Cmd+Shift+Enter` (macOS) or `Ctrl+Shift+Enter` (Windows/Linux) sends the first queued message as a steer without touching your current draft. Remap `thread.steerQueuedMessage` in **Settings → Keybindings**, or add a rule in your [keybindings file](./keybindings.md#edit-the-configuration-file) to trigger it on `mod+enter` when the composer is empty:

```json
{
  "key": "mod+enter",
  "command": "thread.steerQueuedMessage",
  "when": "composerFocus && turnRunning && composerEmpty"
}
```

- **Edit most recently queued message**: `Option+Up` (macOS) or `Alt+Up` (Windows/Linux) at the start of the composer (`thread.editQueuedMessage`).

Slash commands (such as `/compact` or `/context`) wait for the current turn to finish rather than steering into it. [Goal](#goals) commands are the exception.

## Queue messages offline on mobile

Mobile keeps local copies of draft attachments so you can preview them and queue messages offline. Uploads resume on reconnect, and drafts/queued messages survive app restarts and Infinitus Connect sign-out (restored when signing back into the same account).

## Custom models and defaults

- **Remembered defaults**: Infinitus remembers your last provider, model, and options for new threads. A project's configured model overrides this. Leaving reasoning level or service tier unset uses the provider's default.
- **Custom models**: Add unlisted models in **Settings → Providers → Models** (web and desktop; not supported for Antigravity, which uses its account catalog).
- **Rename a built-in model across all clients**: Add an entry in the server's `userdata/settings.json`:

```json
{
  "providerInstances": {
    "codex": {
      "driver": "codex",
      "config": { "customModels": [{ "slug": "gpt-5.5", "name": "Team GPT" }] }
    }
  }
}
```

## Quote an assistant response

- **Web and desktop**: Select text in an assistant message and click **Cite in composer**. Click the pencil on the chip to add or edit a comment; click the chip to jump back to the source.
- **Mobile**: Long-press an assistant response, select text, and tap **Cite**. Tap a quote chip to edit its comment, remove it, or jump to the source message.

Quoted text and comments count toward the message length limit and are preserved across copy/paste and [stashed prompts](#prompt-stash).

## Recall a sent prompt

Press `ArrowUp` in an empty composer to cycle backward through earlier prompts in the thread, and `ArrowDown` to move forward. Only prompt text is restored (not attachments or context chips). Editing a recalled prompt turns it into a normal draft.

## Suggested next prompt

Enable **Settings → Labs → Suggest next prompt** (web and desktop) to show a predicted next message in the empty composer after a Claude or Codex turn completes.

- Press `Tab` to accept or `Escape` to dismiss.
- Each suggestion uses one cached request against your plan's usage. Claude skips suggestions on the first turn and near usage limits.
- Codex requires CLI version 0.165+ (update in **Settings → Providers**). Open Claude threads pick up the setting after restarting.

## Edit an earlier prompt

On web and desktop, select **Edit from here** under a sent message to rewind the conversation to before that message and return it to the composer:

- **Revert and keep changes**: Rewinds the conversation only.
- **Revert files too**: Restores workspace files to the checkpoint before that message (including your own edits). Only available for worktree threads when no other thread or active session shares that directory.

Rewinding removes later messages from the active thread and provider history (requires provider rewind support), but cannot undo external actions or separate provider memory.

## Prompt stash

On web and desktop, press `Cmd+S` (macOS) or `Ctrl+S` (Windows/Linux) to stash the current draft and its attachments (wait for uploads to finish first). Press the same shortcut in an empty composer to restore the stash (or open the stash menu if you have multiple).

- Holds up to 100 prompts in browser storage; stashes are never auto-deleted.
- Stashes with uploaded files must be restored in their original environment. Uploads expire after 24 hours; use **Attach again** or remove expired files before sending.

## Voice input

Dictate into the composer with the microphone button or `mod+shift+d` (web and desktop). Audio stays on-device or goes only to an environment/provider you explicitly choose in **Settings → Voice**. See [Voice input](./voice-input.md) for setup, mobile dictation, and microphone priority.

## Queued messages

<<<<<<< HEAD
On web and desktop, the composer shows **Interrupt** while the agent is working and the draft is
empty. Adding text or attachments replaces it with a send button that shows your
[Follow-up behavior](#send-while-the-agent-is-working): a queue icon for Queue or a steer arrow for
Steer. Click it or press your send shortcut to use that action; a steer goes into the active turn at
its next step. Hold `Cmd` on macOS or `Ctrl` on Windows and Linux to switch the button to the
opposite action, then click, or use the opposite-action shortcut described above.
=======
Queued messages appear at the end of the thread (web/desktop) or above the composer (mobile). From a queued message you can:
>>>>>>> upstream-sync-986826178c-upstream-renamed

- **Send now**: Injects it immediately into a running turn (or moves a slash command to the front of the queue).
- **Edit**: Opens the message and its attachments in the composer without losing your existing draft.
- **Remove**: Cancels the queued message.

If you stop the agent or the server restarts, queued messages pause in order. Click **Resume** in an empty composer (or send a new message) to continue. When the provider supports native continuation, **Resume** continues without sending a new prompt.

## Commands and skills

Type `/` for commands or `$` for skills from the selected environment and provider.

- Skills also appear in the `/` menu unless you disable **Settings → Chat → Show skills in slash menu** (under Advanced).
- Provider commands must start the message; Infinitus commands (like `/model`) and `$` skills work on any line.
- `/compact` reduces context usage when supported by the provider.
- `/clear` starts a fresh provider session in the same thread (earlier messages and diffs stay visible above a **New session** divider).
- After adding or changing skills, plugins, or MCP servers, run **Restart agent session** from the command palette so your next message picks up the new config.
- Turn on **Settings → Appearance → Thread details → Context window** to view reported context usage. For automatic idle compaction on Claude, see [compact long conversations](./providers-claude.md#compact-long-conversations).

## Goals

With Codex, Claude, and OpenCode 2.2.5+, send `/goal <criteria>` (for example, `/goal all tests in packages/api pass`) so the agent keeps working across turns until the goal is met.

- `/goal` shows the current goal; `/goal clear` removes it.
- Codex and OpenCode support `/goal pause` and `/goal resume` (stopping pauses the goal).
- On Claude, stopping ends the current turn but keeps the goal active for your next message.
- Sending a new goal or `/goal resume` while working interrupts the current turn unless queued; `/goal clear` and `/goal pause` interrupt only when the agent is actively working on the goal.

## Context in your message

Attached context—files, terminal excerpts, diff/file review comments, preview annotations, pull requests, and threads—appears as inline chips at your cursor. Click a chip to inspect or open its source; copy/paste and [Prompt stash](#prompt-stash) preserve chips across drafts.

- **Pull requests (`#`)**: On web and desktop, type `#` to browse recent PRs in the current repository (linked PRs appear first), type digits to match by number, or type a word to search by text.
- **Threads (`@`)**: Type `@` and part of a thread title to reference a thread on the same server (or on a linked machine when Linked environments is enabled). You can also drag threads from the sidebar onto the composer, or paste a copied thread link. The prompt carries only a reference—the agent reads the thread on demand. Dropping a thread from an unlinked environment attaches a snapshot transcript file instead.
- **Models (`@`)**: Type `@` and part of a model or provider name (e.g. `@opus` or `@opus:opencode`) to reference a model in your prompt (such as for delegation) without changing the thread's model.
- **Images vs. files**: Images keep a thumbnail shelf above the composer plus optional inline chips; files live only as inline chips (deleting the last chip removes the file).

## Attached files

Select any file chip in a draft or sent message to preview it (syntax-highlighted code/JSON, rendered/raw Markdown/HTML/CSV/TSV, audio playback, and ZIP folder browsing up to 50 MB). Large text files show a truncated preview—save the file to read it in full.

## Images and videos in messages

Select an image or video attachment or link to preview it.

- **Web and desktop**: Right-click media to save it or copy its path/URL.
- **Mobile**: Long-press a thumbnail and choose **Save or share**.

File links point to the file on the environment's machine, so moving or deleting the original breaks the preview—save a copy if you need to keep it.

## Files outside the workspace

Following an agent's file link to a file outside the workspace opens it read-only. External HTML files cannot load neighboring scripts, styles, or images.

## HTML and PDF files in the file viewer

On web and desktop, HTML and PDF files open rendered (HTML previews are sandboxed from your Infinitus session; line-specific HTML links open source view). On mobile, PDFs open in the native iOS viewer or an installed Android viewer.
