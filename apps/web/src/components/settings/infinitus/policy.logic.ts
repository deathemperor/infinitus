import {
  InfinitusPolicy,
  type InfinitusCommandInput,
  type InfinitusFleet,
  type InfinitusManifestCommand,
  type InfinitusPolicySetting,
} from "@infinitus/contracts/infinitus";
import * as Option from "effect/Option";
import * as Schema from "effect/Schema";

/**
 * Settings › Engines › Switching policy: an engine's own policy knobs (swapd
 * `config`), read over `infinitus.command` as `policy <fleet>` and written as
 * `policy-set <fleet> <key> <value>` / `policy-unset <fleet> <key>`. The app
 * sets policy and never runs one of its own, so the rows are the engine's
 * list, in its order, with its help lines: a knob a newer engine adds draws
 * as a text field without a build in between. Pure so the section only
 * renders.
 */

const READ_VERB = "policy";
const SET_VERB = "policy-set";
const UNSET_VERB = "policy-unset";

/** The capability the verbs require, as the `fleets` reply names it. */
const CAPABILITY = "settings";

/** A build whose manifest lists all three verbs; older builds keep the section off. */
export function policySupported(commands: ReadonlyArray<InfinitusManifestCommand>): boolean {
  const names = new Set(commands.map((command) => command.name));
  return names.has(READ_VERB) && names.has(SET_VERB) && names.has(UNSET_VERB);
}

/** The fleets whose engine has policy knobs — gated on the capability, never
    on the engine's name. */
export function policyFleets(fleets: ReadonlyArray<InfinitusFleet>): ReadonlyArray<InfinitusFleet> {
  return fleets.filter((fleet) => fleet.capabilities.includes(CAPABILITY));
}

export function policyReadInput(fleet: string): InfinitusCommandInput {
  return { command: READ_VERB, args: [fleet], options: {} };
}

export function policySetInput(fleet: string, key: string, value: string): InfinitusCommandInput {
  return { command: SET_VERB, args: [fleet, key, value], options: {} };
}

export function policyUnsetInput(fleet: string, key: string): InfinitusCommandInput {
  return { command: UNSET_VERB, args: [fleet, key], options: {} };
}

const decodePolicy = Schema.decodeUnknownOption(InfinitusPolicy);

/** The reply's knobs, or null for a shape this build cannot read. */
export function parsePolicy(result: unknown): InfinitusPolicy | null {
  const decoded = decodePolicy(result);
  return Option.isSome(decoded) ? decoded.value : null;
}

type PolicyControl =
  | { readonly kind: "switch" }
  | { readonly kind: "number" }
  | { readonly kind: "select"; readonly choices: ReadonlyArray<string> }
  | { readonly kind: "text" };

/** One knob as a row: the bare key `policy-set` takes, the engine's help
    line, the control its value's type calls for, and the value and default
    as the field shows them (a list joins with ", "). */
export interface PolicyRow {
  readonly key: string;
  readonly label: string;
  readonly help: string;
  readonly control: PolicyControl;
  readonly value: string;
  /** The switch position; false for every other control. */
  readonly on: boolean;
  readonly isSet: boolean;
  readonly defaultText: string;
}

/** Plain names for the knobs swapd ships; an unknown key reads as itself. */
const LABELS: Readonly<Record<string, string>> = {
  enabled: "Automatic switching",
  threshold: "Switch at (% of the binding window)",
  intervalSeconds: "Poll every (seconds)",
  cooldownSeconds: "Cooldown between switches (seconds)",
  hysteresisPct: "Hysteresis (percentage points)",
  strategy: "Strategy",
  includeApiKeyAccounts: "Rotate onto API-key accounts",
  unhealthyTicks: "Unhealthy after (failed polls)",
  preferred: "Preferred accounts",
  model: "Also switch on these models' weekly limits",
};

/** swapd's `Kind::Choice` for `strategy` (its `settings.rs`), the one knob
    whose value is one of a few words; the engine still refuses anything else
    in its own words, so a value off this list is shown, not hidden. */
const CHOICES: Readonly<Record<string, ReadonlyArray<string>>> = {
  strategy: ["best", "consume-first", "next-available"],
};

function bareKey(key: string): string {
  const dot = key.indexOf(".");
  return dot === -1 ? key : key.slice(dot + 1);
}

function policyValueText(value: unknown): string {
  if (typeof value === "boolean") return value ? "on" : "off";
  if (typeof value === "number") return String(value);
  if (typeof value === "string") return value;
  if (Array.isArray(value)) return value.map(String).join(", ");
  return value === null || value === undefined ? "" : JSON.stringify(value);
}

function controlFor(key: string, value: unknown): PolicyControl {
  const choices = CHOICES[key];
  if (choices !== undefined) return { kind: "select", choices };
  if (typeof value === "boolean") return { kind: "switch" };
  if (typeof value === "number") return { kind: "number" };
  return { kind: "text" };
}

export function policyRows(
  settings: ReadonlyArray<InfinitusPolicySetting>,
): ReadonlyArray<PolicyRow> {
  return settings.map((setting) => {
    const key = bareKey(setting.key);
    return {
      key,
      label: LABELS[key] ?? key,
      help: setting.help,
      control: controlFor(key, setting.value),
      value: policyValueText(setting.value),
      on: setting.value === true,
      isSet: setting.isSet,
      defaultText: policyValueText(setting.default),
    };
  });
}

/** What the field's text becomes on the wire: a list is comma-joined without
    the spaces the field shows, a number or word is sent as typed and trimmed —
    the engine, not this module, refuses a value off the knob's type or range. */
export function policyWireValue(row: PolicyRow, typed: string): string {
  const trimmed = typed.trim();
  if (row.control.kind !== "text") return trimmed;
  return trimmed
    .split(",")
    .map((part) => part.trim())
    .filter((part) => part !== "")
    .join(",");
}
