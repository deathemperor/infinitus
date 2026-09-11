import type { InfinitusCommandInput, InfinitusManifestCommand } from "@t3tools/contracts/infinitus";
import * as Option from "effect/Option";
import * as Schema from "effect/Schema";

/**
 * Settings › Infinitus › Lock (#747): what the pane sends over
 * `infinitus.command` and how it reads the `lock-status` reply. Pure so the
 * pane only renders. The prompts themselves (Touch ID, the password fallback)
 * run on the Mac: `lock on` and `unlock` return once the user answered there.
 */

const LOCK_COMMANDS = ["lock-status", "lock", "unlock"] as const;

/** A build with all three verbs (native #788). */
export function lockCommandsSupported(commands: ReadonlyArray<InfinitusManifestCommand>): boolean {
  const names = new Set(commands.map((command) => command.name));
  return LOCK_COMMANDS.every((name) => names.has(name));
}

export const LockStatus = Schema.Struct({
  enabled: Schema.Boolean,
  locked: Schema.Boolean,
  /** The native relock label: "immediately", "5 min", "1 h", "on sleep". */
  relock: Schema.String,
});
export type LockStatus = typeof LockStatus.Type;

const decodeLockStatus = Schema.decodeUnknownOption(LockStatus);

/** The `lock-status` (and every `lock` / `unlock`) reply, null when the shape is not the one above. */
export function parseLockStatus(result: unknown): LockStatus | null {
  return Option.getOrNull(decodeLockStatus(result));
}

export interface RelockChoice {
  /** What `lock relock <arg>` takes. */
  readonly arg: "immediately" | "5m" | "1h" | "sleep";
  /** What the reply's `relock` says for it. */
  readonly native: string;
  readonly label: string;
}

/** The four relock policies in the Mac's own order and wording. */
export const RELOCK_CHOICES: ReadonlyArray<RelockChoice> = [
  { arg: "immediately", native: "immediately", label: "Immediately" },
  { arg: "5m", native: "5 min", label: "After 5 minutes" },
  { arg: "1h", native: "1 h", label: "After 1 hour" },
  { arg: "sleep", native: "on sleep", label: "When the Mac sleeps" },
];

/** The choice a reply's `relock` label names, null for a label this build does not know. */
export function relockChoiceFor(native: string): RelockChoice | null {
  return RELOCK_CHOICES.find((choice) => choice.native === native) ?? null;
}

export type LockAction =
  | { readonly type: "status" }
  | { readonly type: "on" }
  | { readonly type: "off"; readonly force: boolean }
  | { readonly type: "now" }
  | { readonly type: "relock"; readonly arg: RelockChoice["arg"] }
  | { readonly type: "unlock" };

/** The `infinitus.command` input for one pane action. */
export function lockCommandInput(action: LockAction): InfinitusCommandInput {
  switch (action.type) {
    case "status":
      return { command: "lock-status", args: [], options: {} };
    case "on":
      return { command: "lock", args: ["on"], options: {} };
    case "off":
      return { command: "lock", args: ["off"], options: action.force ? { yes: "true" } : {} };
    case "now":
      return { command: "lock", args: ["now"], options: {} };
    case "relock":
      return { command: "lock", args: ["relock", action.arg], options: {} };
    case "unlock":
      return { command: "unlock", args: [], options: {} };
  }
}

/**
 * `lock off` inside a team is refused until it is asked with `--yes`; the
 * refusal names the teams ("this Mac is in Alpha, Beta; lock off --yes turns
 * the lock off anyway"). Those names, or null for any other error.
 */
export function lockOffRefusalTeams(error: string): ReadonlyArray<string> | null {
  const match = /^this Mac is in (.+); lock off --yes turns the lock off anyway$/.exec(error);
  if (match === null) return null;
  return match[1]!
    .split(",")
    .map((name) => name.trim())
    .filter((name) => name.length > 0);
}
