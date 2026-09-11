import type { EnvironmentId, ProjectId, PromptSnippet } from "@t3tools/contracts";
import { useMemo } from "react";

import { useServerConfigs } from "../../state/entities";

const NO_SNIPPETS: readonly PromptSnippet[] = [];

/**
 * The project's saved prompts (#270 G) from the environment's server config,
 * which carries the server settings, so the `/` menu offers them with no
 * request of its own. Empty without a project or an environment.
 */
export function useProjectPromptSnippets(
  environmentId: EnvironmentId | null,
  projectId: ProjectId | null,
): readonly PromptSnippet[] {
  const serverConfigs = useServerConfigs();
  return useMemo(() => {
    if (environmentId === null || projectId === null) return NO_SNIPPETS;
    return (
      serverConfigs.get(environmentId)?.settings.projectPromptSnippets[projectId] ?? NO_SNIPPETS
    );
  }, [environmentId, projectId, serverConfigs]);
}
