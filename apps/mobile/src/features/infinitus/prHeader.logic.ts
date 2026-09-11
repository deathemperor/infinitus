import type {
  PullRequestChecksState,
  PullRequestMergeability,
  PullRequestReviewDecision,
  PullRequestState,
} from "@t3tools/contracts";

/** What the phone knows about a thread's pull request, from the linked
    snapshot the server pushes or from the row's live summary (#269). Every
    field but `state` may be missing on a host whose cheap read lacks it. */
export interface PrPhaseInput {
  readonly state: PullRequestState | null;
  readonly isDraft?: boolean | null | undefined;
  readonly checksState?: PullRequestChecksState | null | undefined;
  readonly reviewDecision?: PullRequestReviewDecision | null | undefined;
  readonly mergeability?: PullRequestMergeability | null | undefined;
}

/** One phrase for where the pull request stands, in the web's precedence
    (`resolvePullRequestPrimaryControl`): the terminal states first, then a
    conflict, then draft, then the checks, then the review. An open PR with
    green or no checks and no approval is the one waiting on a person. */
export function prPhaseLabel(pr: PrPhaseInput): string {
  if (pr.state === "merged") return "Merged";
  if (pr.state === "closed") return "Closed";
  if (pr.state === null) return "Status pending";
  if (pr.mergeability === "conflicting") return "Conflicts";
  if (pr.isDraft === true) return "Draft";
  if (pr.checksState === "failing") return "Checks failing";
  if (pr.checksState === "pending") return "Checks running";
  if (pr.reviewDecision === "approved") return "Approved";
  if (pr.reviewDecision === "changes-requested") return "Changes requested";
  return "Ready for review";
}

/** Whether the row's phase is the "a person can review this now" one. */
export function prReadyForReview(pr: PrPhaseInput): boolean {
  return prPhaseLabel(pr) === "Ready for review";
}

/** The host page listing a pull request's checks; only GitHub has one at a
    stable path (`…/pull/N/checks`), told apart the way `parseChangeRequestUrl`
    does: a `/pull/` path on a GitHub-ish host. Elsewhere the PR page itself
    is the nearest thing, so the caller drops the item. */
export function prChecksUrl(url: string): string | null {
  let parsed: URL;
  try {
    parsed = new URL(url);
  } catch {
    return null;
  }
  const hostname = parsed.hostname.toLowerCase();
  const gitHubHost =
    hostname === "github.com" ||
    hostname.endsWith(".github.com") ||
    hostname.split(".").includes("github");
  if (!gitHubHost || !/^\/[^/]+\/[^/]+\/pull\/\d+\/?$/.test(parsed.pathname)) return null;
  parsed.pathname = `${parsed.pathname.replace(/\/+$/, "")}/checks`;
  parsed.search = "";
  parsed.hash = "";
  return parsed.toString();
}

export type PrHeaderAction = "open" | "checks" | "ready";

export interface PrHeaderMenuItem {
  readonly action: PrHeaderAction;
  readonly label: string;
  readonly description: string;
  readonly icon: string;
}

/** The menu under the header's PR item: open the PR, its checks when the
    host has a checks page, and "Mark ready for review" while it is a draft
    the server can act on. Read-only otherwise: no merge from the phone. */
export function prHeaderMenuItems(input: {
  readonly pr: PrPhaseInput;
  readonly checksUrl: string | null;
  readonly canRunActions: boolean;
}): ReadonlyArray<PrHeaderMenuItem> {
  const items: PrHeaderMenuItem[] = [
    {
      action: "open",
      label: "Open pull request",
      description: "In the browser",
      icon: "arrow.up.right.square",
    },
  ];
  if (input.checksUrl !== null) {
    items.push({
      action: "checks",
      label: "View checks",
      description: prChecksDescription(input.pr.checksState ?? null),
      icon: "checklist",
    });
  }
  if (input.canRunActions && input.pr.state === "open" && input.pr.isDraft === true) {
    items.push({
      action: "ready",
      label: "Mark ready for review",
      description: "Takes the pull request out of draft",
      icon: "checkmark.circle",
    });
  }
  return items;
}

function prChecksDescription(checksState: PullRequestChecksState | null): string {
  switch (checksState) {
    case "passing":
      return "All checks passed";
    case "failing":
      return "Some checks failed";
    case "pending":
      return "Checks are still running";
    case null:
      return "On the host";
  }
}

/** The header item's own label and the accessibility phrase for it. */
export function prHeaderLabel(number: number): string {
  return `#${number}`;
}
