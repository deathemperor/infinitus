---
name: status
description: One-line summary of the Infinitus fleet — accounts, usage windows, what is waiting — from the Mac app. Use when the user asks how the accounts, limits or sessions are doing.
---

Call the `fleet_status` tool (Infinitus MCP), then `list_sessions`. Answer in
at most three lines: the active account and its tightest window, the next
account in line, and the sessions waiting on the user (by name). No tables.
If the tools report that Infinitus is not running, say so and stop.
