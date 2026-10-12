import {
  LEGACY_T3_PROJECT_FILE_NAME,
  T3_PROJECT_FILE_NAME,
  type EnvironmentId,
  type ProjectReadFileResult,
} from "@infinitus/contracts";

import { projectEnvironment } from "../../state/projects";
import { useEnvironmentQuery } from "../../state/query";

/**
 * Fork (#823 layer 1): the project's checked-in file under both names,
 * `infinitus.json` first and `t3.json` as the legacy fallback, read in the
 * server's order; whichever answers first decides. Stands in for upstream's
 * single `readFile` query in `new-task-flow-provider.tsx` with the same shape.
 */
export function useProjectFileRead(
  project: { readonly environmentId: EnvironmentId; readonly workspaceRoot: string } | null,
  canReadFiles: boolean,
): { readonly data: ProjectReadFileResult | null; readonly isPending: boolean } {
  const target = canReadFiles && project !== null && project.workspaceRoot !== "" ? project : null;
  const readFile = (relativePath: string) =>
    target === null
      ? null
      : projectEnvironment.readFile({
          environmentId: target.environmentId,
          input: { cwd: target.workspaceRoot, relativePath },
        });
  const current = useEnvironmentQuery(readFile(T3_PROJECT_FILE_NAME));
  const legacy = useEnvironmentQuery(readFile(LEGACY_T3_PROJECT_FILE_NAME));
  return {
    data: (current.data ?? legacy.data) as ProjectReadFileResult | null,
    isPending: current.isPending || legacy.isPending,
  };
}
