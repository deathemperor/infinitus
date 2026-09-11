import type { ProjectId, ProjectScript, ServerSettings } from "@t3tools/contracts";

/** Missing entries preserve existing actions; null explicitly resets a checkout to machine defaults. */
export function resolveProjectScripts(
  settings: Pick<ServerSettings, "defaultProjectScripts" | "projectScriptOverrides">,
  project: { id: ProjectId; scripts: readonly ProjectScript[] },
): readonly ProjectScript[] {
  const override = settings.projectScriptOverrides[project.id];
  if (override === null) return settings.defaultProjectScripts;
  return (
    override ?? (project.scripts.length > 0 ? project.scripts : settings.defaultProjectScripts)
  );
}

export function projectScriptsInheritDefaults(
  settings: Pick<ServerSettings, "projectScriptOverrides">,
  project: { id: ProjectId; scripts: readonly ProjectScript[] },
): boolean {
  const override = settings.projectScriptOverrides[project.id];
  return override === null || (override === undefined && project.scripts.length === 0);
}

interface ProjectScriptRuntimeEnvInput {
  project: {
    cwd: string;
  };
  worktreePath?: string | null;
  extraEnv?: Record<string, string>;
}

export function projectScriptCwd(input: {
  project: {
    cwd: string;
  };
  worktreePath?: string | null;
}): string {
  return input.worktreePath ?? input.project.cwd;
}

/**
 * Ten ports per checkout (#270 J): a dev server started by a script binds
 * `$T3CODE_PORT`, so the same script on two worktrees never fights over
 * 3000. The block is derived from the worktree path (the project root for a
 * local-checkout thread), so a worktree keeps its ports across threads and
 * restarts. Blocks live in 10000–29999: below Linux's ephemeral range
 * (32768+) and clear of the usual 3000 / 5173 / 8080 defaults.
 */
export const PROJECT_SCRIPT_PORT_BLOCK_SIZE = 10;
const PORT_BLOCK_FIRST = 10_000;
const PORT_BLOCK_COUNT = 2_000;

function fnv1a32(value: string): number {
  let hash = 0x811c9dc5;
  for (let index = 0; index < value.length; index += 1) {
    hash ^= value.charCodeAt(index);
    hash = Math.imul(hash, 0x01000193) >>> 0;
  }
  return hash;
}

export function projectScriptPortBlock(path: string): {
  readonly start: number;
  readonly end: number;
} {
  const normalized = path.replace(/[\\/]+$/, "");
  const start =
    PORT_BLOCK_FIRST + (fnv1a32(normalized) % PORT_BLOCK_COUNT) * PROJECT_SCRIPT_PORT_BLOCK_SIZE;
  return { start, end: start + PROJECT_SCRIPT_PORT_BLOCK_SIZE - 1 };
}

export function projectScriptRuntimeEnv(
  input: ProjectScriptRuntimeEnvInput,
): Record<string, string> {
  const ports = projectScriptPortBlock(input.worktreePath ?? input.project.cwd);
  const env: Record<string, string> = {
    T3CODE_PROJECT_ROOT: input.project.cwd,
    T3CODE_PORT: String(ports.start),
    T3CODE_PORT_END: String(ports.end),
  };
  if (input.worktreePath) {
    env.T3CODE_WORKTREE_PATH = input.worktreePath;
  }
  if (input.extraEnv) {
    return { ...env, ...input.extraEnv };
  }
  return env;
}

export function setupProjectScript(scripts: readonly ProjectScript[]): ProjectScript | null {
  return scripts.find((script) => script.runOnWorktreeCreate) ?? null;
}
