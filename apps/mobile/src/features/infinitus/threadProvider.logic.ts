import type { EnvironmentThreadShell } from "@infinitus/client-runtime/state/models";
import type { ServerConfig } from "@infinitus/contracts";

/** The provider snapshot a thread runs on, from ITS environment's config: the
    session's instance while one runs, else the thread's model selection. Takes
    one config rather than the whole configs Map so a hook can read it through
    `serverEnvironment.configValueAtom(environmentId)` with a selector and wake
    only when that environment's config changes (#1278 finding 5). */
export function threadProviderSnapshot(
  config: ServerConfig | null,
  thread: Pick<EnvironmentThreadShell, "session" | "modelSelection">,
): ServerConfig["providers"][number] | null {
  const instanceId = thread.session?.providerInstanceId ?? thread.modelSelection.instanceId;
  return config?.providers.find((provider) => provider.instanceId === instanceId) ?? null;
}
