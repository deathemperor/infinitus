# Oh My Pi as a provider driver

`omp` speaks ACP natively (`omp acp`), so the driver is one more tenant of
the existing ACP runtime rather than a protocol of its own. It templates on
Cursor, being another ACP tenant, and differs where `omp` does.

## The ACP session

`buildOmpAcpSpawnInput` puts the launch flags before the `acp` subcommand
(omp hoists the subcommand and forwards leading flags) and passes `--yolo`
only in full access. `resumeMethod: "resume"`, since omp advertises
`sessionCapabilities.resume` and its `session/load` replays the whole
transcript first. `applyOmpAcpModelSelection` drives the session's
`configOptions` (`model`, `thinking`) rather than `session/set_model`, and
reads them live because omp pushes `config_option_update` unsolicited.
`isBareSlashCommand` keeps the runtime-instructions block off a turn that is
only a slash command, since omp joins a prompt's text blocks with a blank
line and reads everything after the command name as that command's arguments
— a `/compact` with a second block compacts toward the block's text.

Only full access auto-approves: omp gates `edit` solely when the payload
rewrites to a delete or a move, and stamps a permission `kind` on bash
alone, so there is nothing an auto-accept-edits branch could answer but the
destructive rewrites that mode is meant to keep asking about.

`setup.canAuthenticate` is left off because omp signs in only through its own
terminal UI, and the UI reads a missing value as "no button".

## Text generation

`OmpTextGeneration.ts` generates titles, commit messages, branch names and PR
bodies over `omp -p` (`--no-tools --no-session --no-title --model`),
templating on OpenCode rather than Codex/Claude because omp has no schema
flag: structure rides in the shared prompt builders and `extractJsonObject`
pulls the JSON object out of free text. `omp -p` writes `Working...\n` to
stderr on a successful run, so a failing spawn strips that spinner before
using stderr as the error detail. `omp-default` is a T3 sentinel, not a real
omp model id, so the model goes through `resolveOmpAcpBaseModelId` first.

## Auth

omp has no auth verb: `omp models --json` answers only once a provider has
usable credentials, so a non-empty catalogue **is** the auth signal. The
corollary is that an _empty_ catalogue means "signed out" only when the
listing actually ran — a probe that failed or timed out reports
`auth: "unknown"` (and skips the usage probe, which would fail the same way)
rather than telling a signed-in user to sign in because their network was
slow.

## Quota

`omp usage --json --redact`'s `capacity` fold (`ompUsage.logic.ts`), chosen
over `limits[]` because it is pre-aggregated across accounts and carries no
email — `limits[]` sits next to `metadata.email`. `resetsAt` is absent as a
consequence. A non-zero exit, timeout or unparseable JSON is `probeFailed`;
empty or missing capacity is `unsupported`. The decode is defensive, so a
future omp shape change degrades to fewer windows rather than a broken probe.

## Slash commands

omp enumerates slash commands only inside an ACP session (`acp-agent.ts`
`#buildAvailableCommands`); its builtin set is ~85 and TUI-heavy, and skills
are filesystem-discovered, so the driver ships `[COMPACT_SLASH_COMMAND]` like
Grok and enumeration waits on an upstream `--json` subcommand.

## Session import

`~/.omp/agent/sessions` (or `PI_CODING_AGENT_DIR`), files
`<ISO-ts>_<sessionId>.jsonl` — the id is the suffix after `_`, not the whole
stem, which would carry the timestamp into the resume cursor. `custom_message`
records are injected system reminders (`display: false`) and are not imported
as user prose. `OmpSettings` has no home field, so the driver adds none. The
importer writes the binding's cursor in the adapter's own shape
(`{ schemaVersion, sessionId }`): every adapter parses only its own, and a
cursor it cannot read starts a blank session without an error.

## Where the pieces live

Fork-only: `apps/server/src/provider/Drivers/OmpDriver.ts`,
`Layers/OmpProvider.ts`, `Layers/OmpAdapter.ts`, `Services/OmpAdapter.ts`,
`acp/OmpAcpSupport.ts`, `Layers/ompUsage.logic.ts`,
`textGeneration/OmpTextGeneration.ts` (each with its test).

Registration points, the ones every driver has:
`packages/contracts/src/settings.ts` (`OmpSettings` / `OmpSettingsPatch` and
the `omp` key of the `providers` struct and its patch — `enabled` defaults to
false, so an upstream install never gains a provider it has no binary for,
with `settings.test.ts` covering the default);
`packages/contracts/src/model.ts` (`DEFAULT_MODEL_BY_PROVIDER.omp`, the
`omp-default` sentinel meaning "whatever the session already selected", and
`PROVIDER_DISPLAY_NAMES.omp`); `apps/server/src/provider/builtInDrivers.ts`;
`apps/server/src/provider/providerStatusCache.ts`;
`apps/server/src/serverSettings.ts` (the five opt-in sites, with
`serverSettings.test.ts`); `apps/server/src/textGeneration/TextGeneration.ts`
(the provider union); `apps/server/scripts/acp-mock-agent.ts` (the
`T3_ACP_OMP=1` profile the adapter tests drive);
`packages/contracts/src/agentSessions.ts` (`"omp"` on `AgentSessionSource`)
and `apps/server/src/project/AgentSessionScanner.ts` (`discoverOmpTranscripts`
plus the parse / retain / home dispatch sites).

Web: `apps/web/src/components/Icons.tsx` (`OmpIcon`),
`chat/providerIconUtils.ts`, `settings/providerDriverMeta.ts`,
`settings/customModelEditor.logic.ts`, `settings/settingsSearch.ts`, and
`components/onboarding/WelcomeWizard.tsx` (`ImportRowMeta` takes
`AgentSessionSource` and draws an omp icon slot; a source added to that union
breaks this file until it does).

Mobile: `apps/mobile/src/components/ProviderIcon.tsx` — its own `omp` branch,
since the fallthrough draws the Codex mark and an unlisted driver is
mislabelled rather than merely unstyled.

Docs: `README.md`'s provider line, `docs/user/install.md`'s provider table and
`PATH` note, and `docs/user/permission-modes.md`'s provider differences (Oh My
Pi never prompts for a plain edit, so **Auto-accept edits** reads as
**Supervised** there).

## Upstream's own Oh My Pi

Upstream `main` carries no omp driver (checked 2026-09-18), but two community
PRs are open for one — `pingdotgg/t3code#11973`, built on current main and a
superset of this driver (its own `Drivers/OmpUsage.ts`, `OmpModelCatalog.ts`,
`OmpCommands.ts`, `OmpSkillDispatch.ts`, `OmpMaintenance.ts` and
`acp/OmpAnsi.ts`), and `#10893`, whose file set is this one's. Both claim the
paths above and the `omp` driver kind, down to `OmpSettings`'
`placeholder: "omp"`. So the sync that brings either in is a collision in the
files listed above, not a second provider appearing beside this one.

Resolve it by keeping this driver whole and dropping upstream's arm at every
shared registration point. Two `omp` keys in one object is a type error at
best; two `case "omp"` branches in a switch compiles and silently runs the
first. This side is the one exercised against the real binary, and the
divergences are deliberate: `DEFAULT_MODEL_BY_PROVIDER.omp` is the
`omp-default` sentinel here and absent in #11973, and the quota fold lives in
`Layers/ompUsage.logic.ts` rather than its `Drivers/OmpUsage.ts`. A duplicate
user page (#11973 adds `docs/user/providers-oh-my-pi.md`) folds into
`docs/user/install.md` and this page instead of landing next to them.
Anything upstream's version does better is a PR of its own here — never a
reason to take their file wholesale mid-merge.
