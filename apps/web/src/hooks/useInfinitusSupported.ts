import { useEnvironments } from "~/state/environments";

/**
 * Whether any connected server drives an Infinitus app. One is enough: the
 * pages that need the app pick their environment themselves, the way the
 * pull requests page does; the callers only decide whether an entry point
 * (a sidebar item, a settings section) leads anywhere at all.
 */
export function useInfinitusSupported(): boolean {
  const { environments } = useEnvironments();
  return environments.some(
    (environment) => environment.serverConfig?.environment.capabilities.infinitus === true,
  );
}
