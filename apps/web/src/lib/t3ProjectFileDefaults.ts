<<<<<<< HEAD
import {
  T3_PROJECT_FILE_NAMES,
  type EnvironmentId,
  type ThreadEnvMode,
} from "@infinitus/contracts";
=======
import { T3_PROJECT_FILE_NAME, type EnvironmentId, type T3ProjectFile } from "@infinitus/contracts";
>>>>>>> upstream-sync-aff9318bf-upstream-renamed
import { parseT3ProjectFile } from "@infinitus/shared/t3ProjectFile";
import { executeAtomQuery } from "@infinitus/client-runtime/state/runtime";

import {
  getProjectFileQueryAtom,
  resolveProjectFileQueryData,
} from "~/components/files/projectFilesQueryState";
import { appAtomRegistry } from "~/rpc/atomRegistry";

/**
<<<<<<< HEAD
 * Read `defaultThreadEnvMode` from the project's checked-in project file.
 *
 * Imperative counterpart to `useT3ProjectFileScripts` for the new-thread
 * path, which resolves defaults at call time rather than render time. The
 * file query atom caches per (environment, cwd), so repeat calls don't
 * re-fetch. Optimistic in-app writes overlay the query result, matching what
 * `useProjectFileQuery` renders. The names are tried in the server's order —
 * `infinitus.json`, then upstream's `t3.json` — and the first file that reads
 * decides. Missing, truncated, or invalid files resolve to null.
=======
 * Read and decode the project's checked-in `t3.json`.
 *
 * Imperative counterpart to `useT3ProjectFileState` for the new-thread path,
 * which resolves defaults at call time rather than render time. The file
 * query atom caches per (environment, cwd), so repeat calls don't re-fetch.
 * Optimistic in-app writes overlay the query result, matching what
 * `useProjectFileQuery` renders. Missing, truncated, or invalid files
 * resolve to null.
>>>>>>> upstream-sync-aff9318bf-upstream-renamed
 */
export async function readT3ProjectFile(
  environmentId: EnvironmentId,
  workspaceRoot: string,
<<<<<<< HEAD
): Promise<ThreadEnvMode | null> {
  for (const fileName of T3_PROJECT_FILE_NAMES) {
    const result = await executeAtomQuery(
      appAtomRegistry,
      getProjectFileQueryAtom(environmentId, workspaceRoot, fileName),
      { reportDefect: false, reportFailure: false },
    );
    const data = resolveProjectFileQueryData(
      environmentId,
      workspaceRoot,
      fileName,
      result._tag === "Success" ? result.value : null,
    );
    if (data === null) continue;
    if (data.truncated) return null;
    return parseT3ProjectFile(data.contents)?.defaultThreadEnvMode ?? null;
  }
  return null;
=======
): Promise<T3ProjectFile | null> {
  const result = await executeAtomQuery(
    appAtomRegistry,
    getProjectFileQueryAtom(environmentId, workspaceRoot, T3_PROJECT_FILE_NAME),
    { reportDefect: false, reportFailure: false },
  );
  const data = resolveProjectFileQueryData(
    environmentId,
    workspaceRoot,
    T3_PROJECT_FILE_NAME,
    result._tag === "Success" ? result.value : null,
  );
  if (data === null || data.truncated) return null;
  return parseT3ProjectFile(data.contents);
>>>>>>> upstream-sync-aff9318bf-upstream-renamed
}
