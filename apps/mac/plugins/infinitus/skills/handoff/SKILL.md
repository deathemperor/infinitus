---
name: handoff
description: Hand the current task to another live Claude Code session on this Mac, by name, with the context it needs. Use when the user says to hand off, pass, or delegate work to a named session.
---

The user names the session (the argument, or ask once if missing). Then:

1. Call `list_sessions` (Infinitus MCP) and match the name case-insensitively; if nothing matches, list the live names and stop.
2. Write the handoff as one message, under 40 lines: the goal in one sentence; what is done, with commits or file paths; what remains, as a numbered list; the constraints that bind (branch, tests to run, rules from CLAUDE.md that bit you); where the working tree is.
3. Send it with `session_message` to that session. Tell the user it was delivered (the tool's outcome) and stop working on the task yourself unless they say otherwise.

Never include secrets, tokens, or pasted credentials in the handoff.
