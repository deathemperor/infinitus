import type {
  InfinitusCommandInput,
  InfinitusManifestCommand,
} from "@infinitus/contracts/infinitus";
import * as Option from "effect/Option";
import * as Schema from "effect/Schema";

/**
 * Settings › Devices, "Crash reports": what the card sends over
 * `infinitus.command` and how it reads the `crashes` reply. The reports are
 * the Mac's own — the phone files its MetricKit crashes there over
 * `crash-report`, the Mac reads its own diagnostic reports — and this is the
 * only place they are shown since the Mac's settings window stopped drawing
 * them. Read-only: the store keeps the newest 50 and prunes itself, so there
 * is nothing to delete here.
 */

const CRASHES_VERB = "crashes";

/** A build whose manifest lists the verb AND answers the app/OS versions with
    it — `--id` and those two fields landed together, so the option in the
    manifest is what tells a newer Mac from an older one. */
export function crashesSupported(commands: ReadonlyArray<InfinitusManifestCommand>): boolean {
  const crashes = commands.find((command) => command.name === CRASHES_VERB);
  return crashes !== undefined && crashes.options.some((option) => option.startsWith("--id"));
}

const CrashReport = Schema.Struct({
  id: Schema.String,
  /** "ios" or "mac". */
  platform: Schema.String,
  device: Schema.String,
  appVersion: Schema.String,
  osVersion: Schema.String,
  /** ISO-8601, as the Mac encodes its dates. */
  at: Schema.String,
  /** "crash" or "hang". */
  kind: Schema.String,
  reason: Schema.String,
  frames: Schema.Array(Schema.String),
  /** Only on a `--id` read: the whole report, raw diagnostic included. */
  transcript: Schema.optionalKey(Schema.String),
});
export type CrashReport = typeof CrashReport.Type;

const CrashesReply = Schema.Struct({ crashes: Schema.Array(CrashReport) });
const decodeCrashes = Schema.decodeUnknownOption(CrashesReply);

/** The reply's reports, null when the shape is not the one above. */
export function parseCrashes(result: unknown): ReadonlyArray<CrashReport> | null {
  return Option.getOrNull(decodeCrashes(result))?.crashes ?? null;
}

/** Every report, newest first as the Mac lists them. */
export function crashesInput(): InfinitusCommandInput {
  return { command: CRASHES_VERB, args: [], options: {} };
}

/** One report with its transcript — what Copy sends. */
export function crashTranscriptInput(id: string): InfinitusCommandInput {
  return { command: CRASHES_VERB, args: [], options: { id } };
}

/** "iPhone · crash · EXC_BAD_ACCESS", the Mac's own summary line. */
export function crashSummary(report: CrashReport): string {
  return `${report.device} · ${report.kind} · ${report.reason}`;
}

/** "Sep 15, 2026 at 12:04 PM · app 0.5.0-alpha.13 · macOS 26.7". */
export function crashDetail(report: CrashReport, locale?: string): string {
  const at = new Date(report.at);
  const when = Number.isNaN(at.getTime())
    ? report.at
    : at.toLocaleString(locale, { dateStyle: "medium", timeStyle: "short" });
  return `${when} · app ${report.appVersion} · ${report.osVersion}`;
}
