import {
  LEGACY_T3_PROJECT_FILE_NAME,
  T3_PROJECT_FILE_NAME,
  type EnvironmentId,
  type T3ProjectFile,
  type T3ProjectFileScript,
} from "@infinitus/contracts";
import { parseT3ProjectFile } from "@infinitus/shared/t3ProjectFile";
import { useMemo } from "react";

import { useProjectFileQuery } from "~/components/files/projectFilesQueryState";

const NO_SCRIPTS: ReadonlyArray<T3ProjectFileScript> = [];

export interface T3ProjectFileState {
  /**
   * - `valid`: the project file exists and decoded.
   * - `invalid`: it exists but fails to decode (the server then ignores the
   *   whole file, including `iconPath` and every script).
   * - `missing`: no readable project file at the workspace root.
   * - `loading`: the file query has not settled yet.
   */
  status: "loading" | "missing" | "invalid" | "valid";
  /** The decoded file when status is `valid`, null otherwise. */
  file: T3ProjectFile | null;
  scripts: ReadonlyArray<T3ProjectFileScript>;
}

/**
 * Decoded state of the project's checked-in project file, including whether
 * the file exists but is broken — which the runtime otherwise swallows
 * silently. `infinitus.json` decides when it exists; a checkout carrying only
 * upstream's `t3.json` is read from that, the server's own order.
 */
export function useT3ProjectFileState(
  environmentId: EnvironmentId,
  cwd: string | null,
): T3ProjectFileState {
  const preferred = useProjectFileQuery(
    environmentId,
    cwd ?? "",
    T3_PROJECT_FILE_NAME,
    cwd !== null,
  );
  const legacy = useProjectFileQuery(
    environmentId,
    cwd ?? "",
    LEGACY_T3_PROJECT_FILE_NAME,
    cwd !== null,
  );
  const query = preferred.data !== null ? preferred : legacy;
  const contents = query.data && !query.data.truncated ? query.data.contents : null;
  const isPending = preferred.isPending || legacy.isPending;
  return useMemo(() => {
    if (contents === null) {
      return {
        status: isPending ? "loading" : "missing",
        file: null,
        scripts: NO_SCRIPTS,
      } as const;
    }
    const file = parseT3ProjectFile(contents);
    if (file === null) {
      return { status: "invalid", file: null, scripts: NO_SCRIPTS } as const;
    }
    return { status: "valid", file, scripts: file.scripts ?? NO_SCRIPTS } as const;
  }, [contents, isPending]);
}

/**
 * Scripts declared in the project's checked-in project file, offered in the
 * scripts menu for import. Missing, truncated, or invalid files resolve to
 * an empty list.
 */
export function useT3ProjectFileScripts(
  environmentId: EnvironmentId,
  cwd: string | null,
): ReadonlyArray<T3ProjectFileScript> {
  return useT3ProjectFileState(environmentId, cwd).scripts;
}
