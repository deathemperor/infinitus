import type { InfinitusManifestCommand, InfinitusProfile } from "@t3tools/contracts/infinitus";
import { InfinitusProfiles } from "@t3tools/contracts/infinitus";
import * as Option from "effect/Option";
import * as Schema from "effect/Schema";

/**
 * The saved session profiles, read and written over the control socket:
 * `profiles`, `profile-set <name> …`, `profile-remove <name>` (native
 * `Sources/InfinitusCore/ControlProtocol.swift:309-321` at a6a18a94d). The
 * reply shape is prose in the manifest, so it is decoded against the
 * hand-written contract here rather than trusted.
 */

/** The three commands this pane needs; an older app answers `manifest` without
    them and the pane says so instead of sending anything. */
const PROFILE_COMMANDS = ["profiles", "profile-set", "profile-remove"] as const;

export function profileCommandsSupported(
  commands: ReadonlyArray<InfinitusManifestCommand>,
): boolean {
  const names = new Set(commands.map((command) => command.name));
  return PROFILE_COMMANDS.every((name) => names.has(name));
}

const decodeProfiles = Schema.decodeUnknownOption(InfinitusProfiles);

/** The `profiles` reply's list, or null when the app answered with something
    this build cannot read. */
export function parseInfinitusProfiles(result: unknown): ReadonlyArray<InfinitusProfile> | null {
  const decoded = decodeProfiles(result);
  return Option.isSome(decoded) ? decoded.value.profiles : null;
}

/**
 * One profile as the pane edits it: every field a text box, because the shape
 * carries seven of them (folder, engine, permission mode, model, system
 * prompt, first prompt, allowed tools) and the app's own Settings › Profiles
 * stays the place to pick engines and modes from a list.
 */
export interface ProfileDraft {
  readonly name: string;
  readonly cwd: string;
  readonly engine: string;
  readonly permissionMode: string;
  readonly model: string;
  readonly systemPrompt: string;
  readonly prompt: string;
  readonly allowTools: string;
}

export const EMPTY_PROFILE_DRAFT: ProfileDraft = {
  name: "",
  cwd: "",
  engine: "",
  permissionMode: "",
  model: "",
  systemPrompt: "",
  prompt: "",
  allowTools: "",
};

/** The allow-list travels as one `--allow "Edit, Bash git"` string, which is
    how the native side parses it back into rules. */
export function profileDraft(profile: InfinitusProfile): ProfileDraft {
  return {
    name: profile.name,
    cwd: profile.cwd ?? "",
    engine: profile.engine ?? "",
    permissionMode: profile.permissionMode ?? "",
    model: profile.model ?? "",
    systemPrompt: profile.systemPrompt ?? "",
    prompt: profile.prompt ?? "",
    allowTools: (profile.allowTools ?? []).join(", "),
  };
}

/**
 * The `profile-set` call one draft makes. Options are keyed without their
 * dashes, and a field left empty is left out — which is how the command clears
 * it, since it replaces the profile with exactly the fields given.
 */
export function profileSetArgs(draft: ProfileDraft): {
  command: "profile-set";
  args: readonly [string];
  options: Readonly<Record<string, string>>;
} {
  const options: Record<string, string> = {};
  const put = (key: string, value: string) => {
    const trimmed = value.trim();
    if (trimmed !== "") options[key] = trimmed;
  };
  put("cwd", draft.cwd);
  put("engine", draft.engine);
  put("mode", draft.permissionMode);
  put("model", draft.model);
  put("system", draft.systemPrompt);
  put("prompt", draft.prompt);
  put("allow", draft.allowTools);
  return { command: "profile-set", args: [draft.name.trim()], options };
}

export function profileRemoveArgs(name: string): {
  command: "profile-remove";
  args: readonly [string];
} {
  return { command: "profile-remove", args: [name] };
}

/** What a row says about a profile under its name: only the fields it fills. */
export function profileSummary(profile: InfinitusProfile): string {
  const parts: Array<string> = [];
  if (profile.cwd !== undefined && profile.cwd !== null) parts.push(profile.cwd);
  if (profile.engine !== undefined && profile.engine !== null) parts.push(profile.engine);
  if (profile.permissionMode !== undefined && profile.permissionMode !== null) {
    parts.push(profile.permissionMode);
  }
  if (profile.model !== undefined && profile.model !== null) parts.push(profile.model);
  const allowed = profile.allowTools ?? [];
  if (allowed.length > 0) parts.push(`allows ${allowed.join(", ")}`);
  return parts.join(" · ");
}
