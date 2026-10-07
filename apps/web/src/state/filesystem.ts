import {
  createFilesystemEnvironmentAtoms,
  resolveFilesystemReadAccess,
} from "@infinitus/client-runtime/state/filesystem";
import type { EnvironmentId } from "@infinitus/contracts";

import { connectionAtomRuntime } from "../connection/runtime";
import { useEnvironmentPresentation } from "./presentation";
import { useEnvironmentQuery } from "./query";
import { environmentSession } from "./session";

export const filesystemEnvironment = createFilesystemEnvironmentAtoms(connectionAtomRuntime);

export function useFilesystemReadAccess(environmentId: EnvironmentId | null) {
  const session = useEnvironmentQuery(
    environmentId === null ? null : environmentSession.sessionStateAtom(environmentId),
  );
  const environment = useEnvironmentPresentation(environmentId);
  return resolveFilesystemReadAccess({
    isCatalogReady: environment.isReady,
    connection: environment.presentation?.connection ?? null,
    session: session.data,
    sessionError: session.error,
  });
}
