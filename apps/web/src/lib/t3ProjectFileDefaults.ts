import {
  T3_PROJECT_FILE_NAMES,
  type EnvironmentId,
  type T3ProjectFile,
} from "@infinitus/contracts";
import { parseT3ProjectFile } from "@infinitus/shared/t3ProjectFile";
import { executeAtomQuery } from "@infinitus/client-runtime/state/runtime";

import {
  getProjectFileQueryAtom,
  resolveProjectFileQueryData,
} from "~/components/files/projectFilesQueryState";
import { appAtomRegistry } from "~/rpc/atomRegistry";

/**
 * The names are tried in the server's order — `infinitus.json`, then
 * upstream's `t3.json` — and the first file that reads decides.
 */
export async function readT3ProjectFile(
  environmentId: EnvironmentId,
  workspaceRoot: string,
): Promise<T3ProjectFile | null> {
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
    if (data === null || data.exists === false) continue;
    if (data.truncated) return null;
    return parseT3ProjectFile(data.contents);
  }
  return null;
}
