import * as AzureDevOps from "@infinitus/source-control-azure-devops/client/definition";
import * as Bitbucket from "@infinitus/source-control-bitbucket/client/definition";
import {
  makeSourceControlClientRegistry,
  readSourceControlHostSettings,
} from "@infinitus/source-control-core/client/definition";
import type { ServerSettings } from "@infinitus/contracts";

export {
  UNKNOWN_SOURCE_CONTROL_CLIENT,
  type ChangeRequestTerminology,
  type SourceControlClientDefinition,
} from "@infinitus/source-control-core/client/definition";
import * as Forgejo from "@infinitus/source-control-forgejo/client/definition";
import * as GitCafe from "@infinitus/source-control-gitcafe/client/definition";
import * as GitHub from "@infinitus/source-control-github/client/definition";
import * as GitLab from "@infinitus/source-control-gitlab/client/definition";

/**
 * GitHub comes first because a repository that has not reported its host yet reads as GitHub,
 * which is what clients have always shown there. A change request URL goes to the first host
 * whose shape it has, so GitCafe, which claims `/pulls/` only on its own hostnames, comes before
 * Forgejo, which claims it everywhere.
 */
const BUILT_IN_SOURCE_CONTROL_CLIENTS = [
  GitHub.definition,
  GitLab.definition,
  GitCafe.definition,
  Forgejo.definition,
  Bitbucket.definition,
  AzureDevOps.definition,
];

export const sourceControlClients = makeSourceControlClientRegistry(
  BUILT_IN_SOURCE_CONTROL_CLIENTS,
);

export type { GitHubSettings } from "@infinitus/source-control-github/client/definition";

export function readGitHubSettings(settings: Pick<ServerSettings, "sourceControlHosts">) {
  return readSourceControlHostSettings(GitHub.settings, settings.sourceControlHosts.github);
}
