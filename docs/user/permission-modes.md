# Permission modes

Permission modes control when an agent needs your approval to act. Choose a mode in the message
composer; it applies to that thread.

Set the default for new threads in **Settings → General → New threads → Permissions**.
Projects can override the environment default. New threads use this setting rather than the
mode of the thread you were viewing. The initial default is **Full access**; existing threads
and modes you choose in a draft keep their permissions.

| Mode                  | Behavior                                                                              |
| --------------------- | ------------------------------------------------------------------------------------- |
| **Supervised**        | Requests approval for commands and file changes.                                      |
| **Auto-accept edits** | Approves file edits automatically; other actions can still require approval.          |
| **Auto**              | Uses the provider's automatic review to approve routine actions and ask about others. |
| **Full access**       | Allows commands and edits without approval prompts.                                   |

Approve or reject requests in the conversation to let the agent continue. Permission modes do
not prevent the agent from asking questions about the task.

## Provider differences

Providers enforce permissions differently. Some read-only actions can proceed in **Supervised**.
**Auto** uses automatic review on Codex, Claude, and Cursor; providers without an equivalent,
including OpenCode, Oh My Pi, and Antigravity, fall back to asking.

For Grok, **Always allow this session** remembers the matching command or tool input. Other
actions still require approval.

Antigravity can still send native approval requests in **Full access**. It only offers remembered
approvals for actions that support them.

Oh My Pi asks before running a shell command or deleting or moving a file, and it edits files
without asking in every mode. **Auto-accept edits** therefore behaves like **Supervised** on it.
**Full access** answers every request automatically.

Pi, despite the shared ancestry, is the opposite: it runs only in **Full access**. It has no
permission system of its own — it runs every tool with the permissions it was started with, and
there is nothing for Infinitus to approve or reject on your behalf. Choosing another mode refuses
to start the session rather than showing a gate that would not hold. Run Pi in a container if you
want the work confined.

See the [provider guides](./install.md#providers) for setup and provider-specific limits.
