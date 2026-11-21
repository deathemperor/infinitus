import * as AzureDevOps from "@infinitus/source-control-azure-devops/shared/definition";
import * as Bitbucket from "@infinitus/source-control-bitbucket/shared/definition";
import { makeSourceControlDefinitionRegistry } from "@infinitus/source-control-core/shared/definition";
import * as CursorOrigin from "@infinitus/source-control-cursor-origin/shared/definition";
import * as Forgejo from "@infinitus/source-control-forgejo/shared/definition";
import * as GitCafe from "@infinitus/source-control-gitcafe/shared/definition";
import * as GitHub from "@infinitus/source-control-github/shared/definition";
import * as GitLab from "@infinitus/source-control-gitlab/shared/definition";
import * as TanStackSource from "@infinitus/source-control-tanstack-source/shared/definition";

export { canonicalizePullRequestUrl as canonicalizeGitCafePullRequestUrl } from "@infinitus/source-control-gitcafe/shared/definition";

/**
 * GitHub comes first as the client default for unknown hosts. GitCafe, TanStack Source and Origin
 * claim URLs first: GitHub and Forgejo accept the same routes on any hostname. TanStack Source is a
 * private beta a server may leave out; clients always know it, for a server that has it.
 */
export function makeBuiltInSourceControlDefinitions(options: { readonly tanStackSource: boolean }) {
  const tanStackSource = options.tanStackSource ? [TanStackSource.definition] : [];
  return makeSourceControlDefinitionRegistry(
    [
      GitHub.definition,
      CursorOrigin.definition,
      GitLab.definition,
      GitCafe.definition,
      ...tanStackSource,
      Forgejo.definition,
      Bitbucket.definition,
      AzureDevOps.definition,
    ],
    {
      claimChangeRequestUrlsFirst: [
        GitCafe.definition.kind,
        ...tanStackSource.map((definition) => definition.kind),
        CursorOrigin.definition.kind,
        AzureDevOps.definition.kind,
      ],
      recognizeRemotesIn: [
        GitCafe.definition.kind,
        ...tanStackSource.map((definition) => definition.kind),
        CursorOrigin.definition.kind,
        Forgejo.definition.kind,
        GitHub.definition.kind,
        GitLab.definition.kind,
        AzureDevOps.definition.kind,
        Bitbucket.definition.kind,
      ],
    },
  );
}

export const builtInSourceControlDefinitions = makeBuiltInSourceControlDefinitions({
  tanStackSource: true,
});
