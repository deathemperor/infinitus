/**
 * The source control drivers this build ships with. Both registries, repository operations and
 * pull requests, iterate this list; a host with no driver here shows up as unsupported.
 *
 * Adding a host means writing its `@infinitus/source-control-<host>` package, adding its driver
 * here, and providing its services' layers in `layer` below.
 *
 * @module sourceControl/builtInDrivers
 */
import * as AzureDevOpsCli from "@infinitus/source-control-azure-devops/server/AzureDevOpsCli";
import * as AzureDevOpsPullRequestCli from "@infinitus/source-control-azure-devops/server/AzureDevOpsPullRequestCli";
import * as AzureDevOpsDriver from "@infinitus/source-control-azure-devops/server/driver";
import * as BitbucketApi from "@infinitus/source-control-bitbucket/server/BitbucketApi";
import * as BitbucketPullRequestApi from "@infinitus/source-control-bitbucket/server/BitbucketPullRequestApi";
import * as BitbucketDriver from "@infinitus/source-control-bitbucket/server/driver";
import * as ForgejoCli from "@infinitus/source-control-forgejo/server/ForgejoCli";
import * as ForgejoDriver from "@infinitus/source-control-forgejo/server/driver";
import * as GitCafeApi from "@infinitus/source-control-gitcafe/server/GitCafeApi";
import * as GitCafeCredentials from "@infinitus/source-control-gitcafe/server/GitCafeCredentials";
import * as GitCafeDriver from "@infinitus/source-control-gitcafe/server/driver";
import * as GitHubApi from "@infinitus/source-control-github/server/GitHubApi";
import * as GitHubPullRequestApi from "@infinitus/source-control-github/server/GitHubPullRequestApi";
import * as GitHubDriver from "@infinitus/source-control-github/server/driver";
import * as GitLabCli from "@infinitus/source-control-gitlab/server/GitLabCli";
import * as GitLabPullRequestCli from "@infinitus/source-control-gitlab/server/GitLabPullRequestCli";
import * as GitLabDriver from "@infinitus/source-control-gitlab/server/driver";
import type { SourceControlDriver } from "@infinitus/source-control-core/server/driver";
import * as Layer from "effect/Layer";

import * as ServerSourceControlHost from "./ServerSourceControlHost.ts";

const drivers = [
  GitHubDriver.driver,
  GitLabDriver.driver,
  AzureDevOpsDriver.driver,
  BitbucketDriver.driver,
  ForgejoDriver.driver,
  GitCafeDriver.driver,
];

/** Every service a built-in driver's `make` needs; the server's layers must provide them all. */
export type BuiltInSourceControlDriversEnv =
  (typeof drivers)[number] extends SourceControlDriver<infer R> ? R : never;

/** Ordered as the hosts appear in discovery. */
export const BUILT_IN_SOURCE_CONTROL_DRIVERS: ReadonlyArray<
  SourceControlDriver<BuiltInSourceControlDriversEnv>
> = drivers;

/** The services the built-in drivers' packages own, plus the host port they all run against. */
export const layer = Layer.mergeAll(
  // `GitHubApi.layerWithDependencies` carries the quota reserve and rate-limit pause every GitHub
  // reader shares, so the server builds it once, here.
  GitHubPullRequestApi.layer.pipe(Layer.provideMerge(GitHubApi.layerWithDependencies)),
  AzureDevOpsPullRequestCli.layer.pipe(Layer.provideMerge(AzureDevOpsCli.layer)),
  BitbucketPullRequestApi.layer.pipe(Layer.provideMerge(BitbucketApi.layer)),
  ForgejoCli.layer,
  GitCafeApi.layer.pipe(Layer.provideMerge(GitCafeCredentials.layer)),
  GitLabPullRequestCli.layer.pipe(Layer.provideMerge(GitLabCli.layer)),
).pipe(Layer.provideMerge(ServerSourceControlHost.layer));
