import {
  InfinitusEngineUpdateCheck,
  type InfinitusCommandInput,
  type InfinitusManifestCommand,
} from "@infinitus/contracts/infinitus";
import * as Option from "effect/Option";
import * as Schema from "effect/Schema";

/**
 * Settings › Engines › engine updates (#1577): `engine-update-check swapd`
 * reads the running version against the newest release for that Mac, and
 * `engine-update swapd` installs it there and relaunches the app. Both run on
 * the environment the page manages, so another machine's engine is updated
 * from this desktop. Pure so the row only renders.
 */

const CHECK_VERB = "engine-update-check";
const UPDATE_VERB = "engine-update";

/** A build whose manifest lists both verbs; older builds keep the row off. */
export function engineUpdateSupported(commands: ReadonlyArray<InfinitusManifestCommand>): boolean {
  const names = new Set(commands.map((command) => command.name));
  return names.has(CHECK_VERB) && names.has(UPDATE_VERB);
}

export function engineUpdateCheckInput(engine: string): InfinitusCommandInput {
  return { command: CHECK_VERB, args: [engine], options: {} };
}

export function engineUpdateInput(engine: string): InfinitusCommandInput {
  return { command: UPDATE_VERB, args: [engine], options: {} };
}

const decodeCheck = Schema.decodeUnknownOption(InfinitusEngineUpdateCheck);

export function parseEngineUpdateCheck(result: unknown): InfinitusEngineUpdateCheck | null {
  const decoded = decodeCheck(result);
  return Option.isSome(decoded) ? decoded.value : null;
}

/** The row's one line: what is newest, whether it is newer than what runs,
    and the fetch's own words when GitHub could not be read. */
export function engineUpdateLine(check: InfinitusEngineUpdateCheck): string {
  if (check.error !== undefined && check.error !== null) {
    return `Could not check for a newer release: ${check.error}`;
  }
  if (check.latest === undefined || check.latest === null) {
    return "The newest release has no build for this Mac yet.";
  }
  if (check.updatable) {
    return `${check.latest} is available (running ${check.current ?? "an unknown version"}).`;
  }
  return `Up to date: ${check.latest} is the newest release.`;
}
