import {
  T3_PROJECT_FILE_NAMES,
  type EnvironmentId,
  type ProjectReadFileResult,
  type T3ProjectFile,
} from "@infinitus/contracts";
import { parseT3ProjectFile } from "@infinitus/shared/t3ProjectFile";
import { executeAtomQuery } from "@infinitus/client-runtime/state/runtime";
import { AsyncResult } from "effect/reactivity";

import {
  getProjectFileQueryAtom,
  resolveProjectFileQueryData,
} from "~/components/files/projectFilesQueryState";
import { appAtomRegistry } from "~/rpc/atomRegistry";

/** `undefined` when no file by this name exists, so the next name is tried. */
function toT3ProjectFile(
  environmentId: EnvironmentId,
  workspaceRoot: string,
  fileName: string,
  result: ProjectReadFileResult | null,
): T3ProjectFile | null | undefined {
  const data = resolveProjectFileQueryData(environmentId, workspaceRoot, fileName, result);
  if (data === null || data.exists === false) return undefined;
  if (data.truncated) return null;
  return parseT3ProjectFile(data.contents);
}

/**
 * The names are tried in the server's order — `infinitus.json`, then
 * upstream's `t3.json` — and the first file that reads decides.
 */
export async function readT3ProjectFile(
  environmentId: EnvironmentId,
  workspaceRoot: string,
  signal?: AbortSignal,
): Promise<T3ProjectFile | null> {
  for (const fileName of T3_PROJECT_FILE_NAMES) {
    const result = await executeAtomQuery(
      appAtomRegistry,
      getProjectFileQueryAtom(environmentId, workspaceRoot, fileName),
      { reportDefect: false, reportFailure: false, signal },
    );
    const file = toT3ProjectFile(
      environmentId,
      workspaceRoot,
      fileName,
      result._tag === "Success" ? result.value : null,
    );
    if (file !== undefined) return file;
  }
  return null;
}

/** The project's file from an earlier read, or `undefined` when none has loaded yet. */
export function peekT3ProjectFile(
  environmentId: EnvironmentId,
  workspaceRoot: string,
): T3ProjectFile | null | undefined {
  for (const fileName of T3_PROJECT_FILE_NAMES) {
    const result = appAtomRegistry.get(
      getProjectFileQueryAtom(environmentId, workspaceRoot, fileName),
    );
    if (!AsyncResult.isSuccess(result)) return undefined;
    const file = toT3ProjectFile(environmentId, workspaceRoot, fileName, result.value);
    if (file !== undefined) return file;
  }
  return null;
}
