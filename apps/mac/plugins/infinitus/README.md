# Infinitus plugin for Claude Code

Three hooks, one script: `Notification`, `UserPromptSubmit` and `Stop`
pipe their payload to `infinitusctl event`. A fourth, `PreToolUse`, asks
`infinitusctl approve` whether the phone chose "Allow for this session"
for that tool (Bash rules are per command verb: allowing `git` never
allows `rm`); a yes skips the prompt, anything else is silence. The Mac app pushes a
permission or question to your phone the moment it appears (the poll
alone takes up to a minute) and refreshes the fleet when a prompt goes in
or a turn ends, so the session's status and goal follow within a second. Nothing here can block a session —
the script exits 0 whether the app is running or not.

An MCP server (`infinitusctl mcp`, wired by `.mcp.json`) gives every
session three tools — `fleet_status`, `list_sessions`, `session_message`
(send text to another live session by pid or name); the `/infinitus:status`
skill answers "how are the accounts doing" in three lines from them, and
`/infinitus:handoff <session>` passes the current task, with its context, to
another live session.

Install: `infinitusctl plugin install` (or `claude plugin marketplace add
deathemperor/infinitus` then `claude plugin install infinitus@infinitus`).
Set `INFINITUS_CTL` when `infinitusctl` is neither on PATH nor in
`/Applications/Infinitus.app`.
