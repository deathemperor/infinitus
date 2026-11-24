import type { PullRequestChangeBreakdown } from "@infinitus/contracts";
import { summarizeChangedFiles } from "@infinitus/shared/changedFileKind";
import type { ProviderFileStats } from "@infinitus/source-control-core/server/PullRequestProvider";

export function toChangeBreakdown(stats: ProviderFileStats): PullRequestChangeBreakdown {
  if (stats.truncated) return null;
  return summarizeChangedFiles(stats.files);
}
