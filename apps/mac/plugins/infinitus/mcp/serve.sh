#!/bin/sh
# Starts the Infinitus MCP server (`infinitusctl mcp`) for Claude Code (#79).
ctl="${INFINITUS_CTL:-$(command -v infinitusctl 2>/dev/null)}"
[ -x "$ctl" ] || ctl=/Applications/Infinitus.app/Contents/MacOS/infinitusctl
[ -x "$ctl" ] || { echo "infinitusctl not found: install Infinitus or set INFINITUS_CTL" >&2; exit 1; }
exec "$ctl" mcp
