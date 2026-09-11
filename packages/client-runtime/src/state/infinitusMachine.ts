import * as Schema from "effect/Schema";

/**
 * The Machine page's read model (#659): the `machine` reply — native's
 * `MachineReport` (`Sources/InfinitusCore/Machine/MachineReport.swift`) —
 * decoded defensively and folded the way the pop-out's Machine pane draws it
 * (`Sources/Infinitus/MachinePane.swift`). Only the fields the page renders
 * are declared: the report is wide, Swift enums travel in their default
 * `{"case": {"_0": …}}` shape, and native already derives `owner` and
 * `ownerKind` from them. A field that is missing reads as zero, never as a
 * throw; a reply this module cannot read at all is null.
 */

const Count = Schema.optionalKey(Schema.Finite);

const SamplePayload = Schema.Struct({
  at: Schema.String,
  cores: Count,
  load1: Count,
  load5: Count,
  swapUsedMB: Count,
  swapTotalMB: Count,
  processes: Count,
  running: Count,
  uninterruptible: Count,
  zombies: Count,
  windowServerCPU: Count,
  /** Absent when listing the temp directory timed out. */
  tempEntries: Count,
  claudeRSSMB: Count,
});
export type MachineSample = typeof SamplePayload.Type;

const HookPayload = Schema.Struct({
  registration: Schema.Struct({
    event: Schema.String,
    command: Schema.String,
    ownerKind: Schema.String,
    owner: Schema.String,
  }),
  spawnsPerHour: Count,
  live: Schema.Struct({
    instances: Count,
    helpers: Count,
    oldestSeconds: Count,
    uninterruptible: Count,
  }),
});
export type MachineHook = typeof HookPayload.Type;

const RunawayPayload = Schema.Struct({
  pid: Schema.Finite,
  command: Schema.String,
  rule: Schema.String,
  why: Schema.String,
  rssMB: Count,
  elapsedSeconds: Count,
});
export type MachineRunaway = typeof RunawayPayload.Type;

const ResiduePayload = Schema.Struct({
  staleSockets: Count,
  staleSessionEnvs: Count,
  tempEntries: Count,
  transcriptsBytes: Count,
  pluginCacheBytes: Count,
  memBytes: Count,
});
export type MachineResidue = typeof ResiduePayload.Type;

const SessionPayload = Schema.Struct({
  pid: Schema.Finite,
  name: Schema.String,
  cwd: Schema.String,
  rssMB: Count,
  ageSeconds: Count,
  lastActivityAt: Schema.optionalKey(Schema.String),
});
export type MachineSession = typeof SessionPayload.Type;

const ReportPayload = Schema.Struct({
  sample: SamplePayload,
  hooks: Schema.Array(HookPayload),
  runaways: Schema.Array(RunawayPayload),
  residue: ResiduePayload,
  sessions: Schema.Array(SessionPayload),
  warnings: Schema.Array(Schema.String),
});
export type MachineReport = typeof ReportPayload.Type;

/** `machine` before the first sample: native starts one and says so. */
const SamplingPayload = Schema.Struct({ sampling: Schema.Literal(true) });

const decodeReport = Schema.decodeUnknownOption(ReportPayload);
const decodeSampling = Schema.decodeUnknownOption(SamplingPayload);

export type MachineReply =
  | { readonly _tag: "report"; readonly report: MachineReport }
  | { readonly _tag: "sampling" };

/** The `machine` reply as a report, the sampling marker, or null for
    anything else. */
export function decodeMachineReply(result: unknown): MachineReply | null {
  const report = decodeReport(result);
  if (report._tag === "Some") return { _tag: "report", report: report.value };
  return decodeSampling(result)._tag === "Some" ? { _tag: "sampling" } : null;
}

// MARK: hooks

const n = (value: number | undefined): number => value ?? 0;

/** `HookInventory.heavyMarkers` (HookInventory.swift:83): a hook whose
    command starts an interpreter or a network client. Kept verbatim. */
const HEAVY_MARKERS = [
  "python3",
  "python ",
  "node ",
  'node"',
  "bun ",
  "bunx ",
  "osascript",
  "curl ",
  "ruby ",
  "deno ",
  "npx ",
  "System Events",
];
export const isHeavyHook = (command: string): boolean =>
  HEAVY_MARKERS.some((marker) => command.includes(marker));

/** `MachineReport.Hook.risky` / `.stuck` (MachineReport.swift:16-17). */
const hookIsRisky = (hook: MachineHook): boolean =>
  isHeavyHook(hook.registration.command) && n(hook.spawnsPerHour) >= 100;
const hookIsStuck = (hook: MachineHook): boolean =>
  n(hook.live.instances) >= 50 ||
  n(hook.live.oldestSeconds) >= 600 ||
  n(hook.live.uninterruptible) > 0;

const OWNER_KIND_LABELS: Readonly<Record<string, string>> = {
  brew: "Brew",
  vendored: "Vendored",
  handInstalled: "Hand-installed",
  plugin: "Plugin",
  unknown: "Unknown",
};

/** `MachinePane.kindLabel`; a kind this build does not know is shown as-is,
    capitalised. */
export function ownerKindLabel(kind: string): string {
  return OWNER_KIND_LABELS[kind] ?? kind.charAt(0).toUpperCase() + kind.slice(1);
}

/** One owner's hooks folded together, the pane's row. */
export interface HookGroup {
  readonly owner: string;
  readonly kind: string;
  readonly registrations: number;
  /** Any of the owner's hooks is heavy and spawns 100+ times an hour. */
  readonly risky: boolean;
  readonly instances: number;
  readonly helpers: number;
  readonly oldestSeconds: number;
  readonly stuck: number;
  readonly spawnsPerHour: number;
  /** The events it registered on, in first-seen order. */
  readonly events: ReadonlyArray<string>;
}

/** Hooks grouped by owner. Native's pane sorts the groups by owner name;
    here the ones that need a look come first — stuck, then live instances,
    then expected spawns an hour — and the page shows the top of the list
    with the rest behind "Show all". */
export function hookGroups(hooks: ReadonlyArray<MachineHook>): ReadonlyArray<HookGroup> {
  const groups = new Map<string, HookGroup>();
  for (const hook of hooks) {
    const r = hook.registration;
    const current = groups.get(r.owner) ?? {
      owner: r.owner,
      kind: r.ownerKind,
      registrations: 0,
      risky: false,
      instances: 0,
      helpers: 0,
      oldestSeconds: 0,
      stuck: 0,
      spawnsPerHour: 0,
      events: [],
    };
    groups.set(r.owner, {
      ...current,
      registrations: current.registrations + 1,
      risky: current.risky || hookIsRisky(hook),
      instances: current.instances + n(hook.live.instances),
      helpers: current.helpers + n(hook.live.helpers),
      oldestSeconds: Math.max(current.oldestSeconds, n(hook.live.oldestSeconds)),
      stuck: current.stuck + (hookIsStuck(hook) ? 1 : 0),
      spawnsPerHour: current.spawnsPerHour + n(hook.spawnsPerHour),
      events: current.events.includes(r.event) ? current.events : [...current.events, r.event],
    });
  }
  return [...groups.values()].sort(
    (a, b) =>
      b.stuck - a.stuck ||
      b.instances - a.instances ||
      b.spawnsPerHour - a.spawnsPerHour ||
      a.owner.localeCompare(b.owner),
  );
}

// MARK: formatting (MachinePane's cells)

/** `MachinePane.bytesString`: "12 KB" / "1.2 MB" / "3.4 GB". */
export function bytesText(bytes: number): string {
  if (bytes >= 1_073_741_824) return `${(bytes / 1_073_741_824).toFixed(1)} GB`;
  if (bytes >= 1_048_576) return `${(bytes / 1_048_576).toFixed(1)} MB`;
  return `${Math.round(bytes / 1024)} KB`;
}

/** Whole minutes: "0 min" / "12 min". */
export const minutesText = (seconds: number): string => `${Math.floor(seconds / 60)} min`;

/** Idle hours since a session's last activity, for the sessions table;
    null when native did not record one. */
export function idleHours(session: MachineSession, nowMs: number): number | null {
  if (session.lastActivityAt === undefined) return null;
  const at = Date.parse(session.lastActivityAt);
  if (Number.isNaN(at)) return null;
  return Math.max(0, Math.floor((nowMs - at) / 3_600_000));
}
