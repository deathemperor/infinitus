# The Pi driver

Pi ([`@earendil-works/pi-coding-agent`](https://www.npmjs.com/package/@earendil-works/pi-coding-agent),
binary `pi`) is the one shipped provider that speaks neither ACP nor an
app-server protocol. It has its own line-delimited JSON RPC, reached with
`pi --mode rpc`. Everything below is what that protocol does differently from
the ones the other adapters were written against; the code carries the rest.

## Pi is not Oh My Pi

`@oh-my-pi/pi-coding-agent` is a fork of Pi that speaks ACP. It kept
`APP_NAME = "pi"`, so it reads the same `PI_CODING_AGENT_DIR` environment
variable and, left alone, the same `~/.pi/agent` session store. Nothing about
the ACP adapters transfers here, and an ambient `PI_CODING_AGENT_DIR` set for
one of the two would silently redirect the other — `piHomeEnvironment` strips
the inherited variable and re-sets it only from the instance's own configured
home.

Every way we spawn the binary goes through that one helper: the RPC session,
the status probe, and the one-shot `pi -p` runs behind commit messages and
thread titles. A path that skips it does not merely miss a setting — it reads
Oh My Pi's credentials and models and reports them as Pi's.

## Framing: LF and nothing else

Pi terminates records with `\n` alone. A splitter that also breaks on `\r`,
U+2028 or U+2029 corrupts payloads, because those characters appear inside
the JSON strings Pi sends — a model quoting a file, or emitting a line
separator in prose.

Both obvious choices are wrong for this. Node's `readline` splits on U+2028
and U+2029; Effect's `Stream.splitLines` splits on `\r`. Hence
`splitPiRpcLines` in `piRpcProtocol.ts`, which splits on `\n` and treats
everything else as payload. `piRpcProtocol.test.ts` pins all three cases.

## Only `agent_settled` ends a turn

Pi emits several events that look terminal and are not:

- `turn_end` fires per low-level agent turn. A prompt that calls a tool emits
  **two** `turn_start`/`turn_end` pairs — one for the tool, one for the reply.
- `agent_end` precedes an automatic retry and a compaction retry, so it can be
  followed by more of the same turn.

`agent_settled` is the only event meaning Pi has stopped working on the
prompt. Keying a turn on either of the others settles it while work is still
running, and the reply then lands outside the turn.

The other way a turn ends without any of these: a `response` with
`success: false` for a `prompt` command. Pi rejected the prompt before
accepting it, and **no events follow at all** — the adapter settles the turn
as failed from that arm, or it waits forever.

## Thinking and text are separate streams

`message_update` carries an `assistantMessageEvent` whose `type` is
`text_delta` or `thinking_delta`, each on its own `contentIndex`.
Accumulating `delta` without switching on that `type` glues the model's
private reasoning onto its answer. One probe sample carried 25 thinking
deltas to 1 text delta.

`message_start` / `message_end` are echoed for the **user** message and for
tool results too, so the message's `role` has to be checked before any of it
is treated as assistant output.

## Abort is acknowledged late

Pi answers `abort` only once the session has gone idle — its own docs say the
command waits for that, and a live run took 14 seconds. The abort itself
works immediately: streaming stops and the turn's `message_end` carries
`stopReason: "aborted"`. So `interruptTurn` fires the command and does not
await the acknowledgement. Awaiting it would block the caller for the rest of
the turn, which is the opposite of interrupting.

No `message_end` settles a turn, only `agent_settled`, which Pi always emits
last. After an aborted message Pi is still busy and refuses the next prompt;
after an errored one (`stopReason: "error"`, with `errorMessage`) it may
retry. The adapter remembers how the latest assistant message ended and reads
that at `agent_settled`, so a model or auth failure is a failed turn instead
of an empty completed one. The cost is that `turn.aborted` waits for Pi's
wind-down too; reporting it earlier would let the user send a prompt Pi
refuses.

## No permission system

Pi runs every tool with the permissions of the process that launched it. Its
RPC protocol has no approval request to answer — a live run wrote a file with
no permission event of any kind. The driver refuses the supervised runtime
modes rather than presenting a gate it cannot enforce, and the provider
snapshot hides the interaction-mode toggle.

## Model binding and sessions

`--model` is read at spawn, so a mid-session model switch means a new
process; the adapter advertises `sessionModelSwitch: "unsupported"` and the
orchestration layer restarts the session.

`--session-id` is exact and creates the session when it is absent, so a fresh
session and a resumed one take the identical code path — the resume cursor is
just that id. Pi forks a session rather than rewinding one, so there is no
provider-side rollback.

One-shot runs (`pi -p`, used for commit messages and thread titles) pass
`--no-session`. Pi otherwise writes them into `sessions/<cwd>/` exactly like a
real conversation, and the project scanner then offers our own internal
prompts back to the user as importable history — found by scanning a copy of a
real `~/.pi/agent`, which held eight "Generate a title…" transcripts. They
also pass `--no-tools`: the prompt carries an unvetted diff and Pi has no
permission gate.

Auth has no verb to ask: Pi lists a model in `--list-models` only once its
provider has usable credentials, so a non-empty catalogue **is** the auth
signal. Signed out, Pi still exits 0 and prints one line of prose ("No models
available. Use /login …"), so the parser reads rows only below the table
header. The corollary is that an _empty_ catalogue only means "signed out"
when the listing actually ran — a probe that failed or timed out reports
`auth: "unknown"`, the way the other providers do, rather than telling a
signed-in user to sign in because their network was slow.

## Transcripts on disk

Pi writes `sessions/<slug-of-cwd>/<timestamp>_<sessionId>.jsonl` under its
home. Two things follow for the project scanner:

- **The directory name is lossy**, so the real working directory has to come
  from each transcript's own `session` header record, not from the slug.
- **The filename is not a session id.** Unlike Claude, whose filenames _are_
  ids, Pi's carry a leading timestamp — only the `session` header's `id` is
  resumable.

Records are `{type: "message", message: {role, content}}`, with `model_change`
carrying the model as its own record. Assistant content mixes `text` and
`thinking` blocks; only text-ish blocks are extracted, so the model's private
reasoning never reaches an imported thread.

The scanner resolves Pi's home from the instance's `homePath` setting alone,
defaulting to `~/.pi/agent`. It deliberately consults no environment variable
— see "Pi is not Oh My Pi" above. Pi also ships disabled, so a scan reads that
home only once the user has turned the provider on.
