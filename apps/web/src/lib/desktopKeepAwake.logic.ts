import type { EnvironmentId, OrchestrationSessionStatus } from "@t3tools/contracts";

/**
 * Fork (#1075): whether the desktop shell should hold off sleep. True while
 * the setting is on and any thread on the primary environment — the server
 * this window runs — has a turn starting or running, the sidebar's
 * "working" reading. Remote environments never count: their turns run on
 * another machine.
 */
export function keepAwakeWanted(input: {
  readonly enabled: boolean;
  readonly primaryEnvironmentId: EnvironmentId | null;
  readonly shells: ReadonlyArray<{
    readonly environmentId: EnvironmentId;
    readonly session?: { readonly status: OrchestrationSessionStatus } | null;
  }>;
}): boolean {
  if (!input.enabled || input.primaryEnvironmentId === null) return false;
  return input.shells.some(
    (shell) =>
      shell.environmentId === input.primaryEnvironmentId &&
      (shell.session?.status === "starting" || shell.session?.status === "running"),
  );
}
