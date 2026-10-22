import type {
  EnvironmentProject,
  EnvironmentThreadShell,
} from "@infinitus/client-runtime/state/shell";

import { scopedProjectKey } from "../../lib/scopedEntities";
import { isDraftThreadRoute } from "../threads/thread-route-state";

export interface ShareTargetThread {
  readonly thread: EnvironmentThreadShell;
  readonly projectTitle: string | null;
}

/**
 * Threads a native share can land in: unarchived, newest activity first,
 * narrowed by a case-insensitive match on the thread or project title.
 */
export function selectShareTargetThreads(input: {
  readonly threads: ReadonlyArray<EnvironmentThreadShell>;
  readonly projects: ReadonlyArray<EnvironmentProject>;
  readonly query: string;
}): ReadonlyArray<ShareTargetThread> {
  const projectTitles = new Map(
    input.projects.map((project) => [
      scopedProjectKey(project.environmentId, project.id),
      project.title,
    ]),
  );
  const query = input.query.trim().toLowerCase();
  return input.threads
    .filter((thread) => thread.archivedAt === null)
    .map((thread) => ({
      thread,
      projectTitle:
        projectTitles.get(scopedProjectKey(thread.environmentId, thread.projectId)) ?? null,
    }))
    .filter(
      (row) =>
        query === "" ||
        row.thread.title.toLowerCase().includes(query) ||
        (row.projectTitle?.toLowerCase().includes(query) ?? false),
    )
    .sort((a, b) => Date.parse(b.thread.updatedAt) - Date.parse(a.thread.updatedAt));
}

/**
 * Whether a root-stack route belongs to the new-task flow a share opens: the
 * draft thread and the pickers pushed over it. `Stack.tsx` counts the share as
 * still presented while one of these is on top, so opening the project picker
 * does not read as closing the draft (which discards the share), and the
 * share-to-thread screen pops all of them when it opens the chosen thread.
 */
export function isShareFlowRoute(
  route: { readonly name: string; readonly params?: object } | undefined,
): boolean {
  if (route === undefined) return false;
  return (
    isDraftThreadRoute(route) ||
    route.name.startsWith("NewTask") ||
    route.name.startsWith("AddProject")
  );
}
