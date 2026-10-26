import * as AzureDevOpsDriver from "@infinitus/source-control-azure-devops/server/driver";
import * as BitbucketDriver from "@infinitus/source-control-bitbucket/server/driver";
import { builtInSourceControlDefinitions } from "@infinitus/source-control-definitions/registry";
import * as ForgejoDriver from "@infinitus/source-control-forgejo/server/driver";
import * as GitCafeDriver from "@infinitus/source-control-gitcafe/server/driver";
import * as GitHubDriver from "@infinitus/source-control-github/server/driver";
import * as GitLabDriver from "@infinitus/source-control-gitlab/server/driver";

/** In the shared registry's order, which is the order hosts are listed and probed in. */
export const BUILT_IN_SOURCE_CONTROL_DRIVER_LIST = [
  GitHubDriver.driver,
  GitLabDriver.driver,
  GitCafeDriver.driver,
  ForgejoDriver.driver,
  BitbucketDriver.driver,
  AzureDevOpsDriver.driver,
] as const;

export const sourceControlDefinitions = builtInSourceControlDefinitions;
