import {
  resolveChangeRequestLinkTarget,
  type ChangeRequestLinkCapabilities,
} from "@infinitus/client-runtime/change-request-links";
import type { EnvironmentProject } from "@infinitus/client-runtime/state/shell";
import { EnvironmentId, ProjectId } from "@infinitus/contracts";

/** The PullRequest route for a change request link from a project, or null for the browser. */
export function nativePullRequestDestination(
  url: string,
  context: { environmentId: string; projectId: string } | null,
  projects: ReadonlyArray<Pick<EnvironmentProject, "id" | "environmentId" | "repositoryIdentity">>,
  capabilities: (environmentId: EnvironmentId) => ChangeRequestLinkCapabilities | undefined,
) {
  if (!context) return null;
  const target = resolveChangeRequestLinkTarget({
    url,
    projects,
    capabilities,
    environmentId: EnvironmentId.make(context.environmentId),
    projectId: ProjectId.make(context.projectId),
    lendHostProject: true,
  });
  if (target === null) return null;
  return {
    environmentId: context.environmentId,
    projectId: String(target.project.id),
    repository: target.repository,
    number: target.number,
    ...(target.host === undefined ? {} : { host: target.host }),
  };
}
