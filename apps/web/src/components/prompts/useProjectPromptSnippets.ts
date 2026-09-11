import type { PromptSnippet } from "@t3tools/contracts";
import { useMemo } from "react";

import { useClientSettings, useEnvironmentSettings } from "../../hooks/useSettings";
import { derivePhysicalProjectKey, selectProjectGroupingSettings } from "../../logicalProject";
import { buildPhysicalToLogicalProjectKeyMap } from "../../sidebarProjectGrouping";
import { useProjects } from "../../state/entities";
import { usePrimaryEnvironmentId } from "../../state/environments";
import type { ActiveProjectRef } from "../captures/useCaptures";
import { snippetsForProject } from "./promptSnippets.logic";

/**
 * The composer's view of a project's saved prompts (#270 G): the list from
 * that project's server settings and the settings-page key the Prompts menu
 * links to. `project` is the routed thread's, null on a draft without one.
 */
export function useProjectPromptSnippets(project: ActiveProjectRef | null): {
  readonly snippets: readonly PromptSnippet[];
  readonly projectKey: string | null;
} {
  const settings = useEnvironmentSettings(project?.environmentId ?? PLACEHOLDER_ENVIRONMENT);
  const projects = useProjects();
  const grouping = useClientSettings(selectProjectGroupingSettings);
  const primaryEnvironmentId = usePrimaryEnvironmentId();
  return useMemo(() => {
    if (project === null) return { snippets: [], projectKey: null };
    const record = projects.find(
      (item) => item.environmentId === project.environmentId && item.id === project.projectId,
    );
    const projectKey =
      record === undefined
        ? null
        : (buildPhysicalToLogicalProjectKeyMap({
            projects,
            settings: grouping,
            primaryEnvironmentId,
          }).get(derivePhysicalProjectKey(record)) ?? null);
    return { snippets: snippetsForProject(settings, project.projectId), projectKey };
  }, [grouping, primaryEnvironmentId, project, projects, settings]);
}

// `useEnvironmentSettings` needs an id every render; with no project the
// value is unused, and an unknown id resolves to the defaults.
const PLACEHOLDER_ENVIRONMENT = "" as ActiveProjectRef["environmentId"];
