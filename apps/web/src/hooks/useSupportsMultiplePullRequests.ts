import type { EnvironmentId } from "@infinitus/contracts";
import { useServerConfigs } from "~/state/entities";

export function useSupportsMultiplePullRequests(environmentId: EnvironmentId | null): boolean {
  const configs = useServerConfigs();
  return (
    environmentId !== null &&
    configs.get(environmentId)?.environment.capabilities.threadPullRequests === true
  );
}
