import type { EnvironmentThreadShell } from "@infinitus/client-runtime/state/models";
import type { ServerConfig } from "@infinitus/contracts";

/** The provider snapshot a thread runs on, from ITS environment's config. Takes
    one config rather than the whole configs Map so a hook can read it through
    `serverEnvironment.configValueAtom(environmentId)` with a selector and wake
    only when that environment's config changes (#1278 finding 5). */
export function threadProviderSnapshot(
  config: ServerConfig | null,
  thread: Pick<EnvironmentThreadShell, "providerInstanceId">,
): ServerConfig["providers"][number] | null {
  return (
    config?.providers.find((provider) => provider.instanceId === thread.providerInstanceId) ?? null
  );
}
