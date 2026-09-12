import {
  BABYSIT_MAX_ROUNDS,
  type PullRequestChecksState,
  type PullRequestMergeability,
  type PullRequestReviewDecision,
  type PullRequestState,
  type ThreadBabysit,
  type ThreadPullRequestLink,
} from "@t3tools/contracts";
import { resolveThreadCurrentPullRequestLink } from "@t3tools/shared/threadPullRequests";

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

/** The thread list's version (#269 F): the thread's current linked pull
    request, from the snapshot the server pushes with the thread, is open,
    out of draft, with no failing or running checks and no verdict yet. A
    thread whose server does not push links, or whose link has not synced,
    is never "ready for review" — the row keeps its time label. */
export function threadReadyForReview(
  pullRequests: ReadonlyArray<ThreadPullRequestLink>,
  supportsLinks: boolean,
): boolean {
  if (!supportsLinks) return false;
  const snapshot = resolveThreadCurrentPullRequestLink(pullRequests)?.snapshot ?? null;
  if (snapshot === null) return false;
  return prReadyForReview({
    state: snapshot.state,
    isDraft: snapshot.isDraft,
    checksState: snapshot.checksState,
    reviewDecision: snapshot.reviewDecision,
    mergeability: snapshot.mergeability,
  });
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

export type PrHeaderAction = "open" | "checks" | "ready" | "babysit-on" | "babysit-off";

export interface PrHeaderMenuItem {
  readonly action: PrHeaderAction;
  readonly label: string;
  readonly description: string;
  readonly icon: string;
}

/** The menu under the header's PR item: open the PR, its checks when the
    host has a checks page, "Mark ready for review" while it is a draft the
    server can act on, and — on an Infinitus server, while the PR is open
    or the thread is already babysat (#269 A, the web's gate) — the babysit
    toggle. Read-only otherwise: no merge from the phone. */
export function prHeaderMenuItems(input: {
  readonly pr: PrPhaseInput;
  readonly checksUrl: string | null;
  readonly canRunActions: boolean;
  /** Null when the server cannot babysit; else the thread's state, null while off. */
  readonly babysit?: { readonly state: ThreadBabysit | null } | null;
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
  const babysit = input.babysit ?? null;
  if (babysit !== null && (babysit.state !== null || input.pr.state === "open")) {
    items.push(
      babysit.state === null
        ? {
            action: "babysit-on",
            label: "Babysit",
            description:
              "Queue a fix round when it conflicts, fails checks or gets changes requested",
            icon: "arrow.triangle.2.circlepath",
          }
        : {
            action: "babysit-off",
            label: `Stop babysitting (${babysit.state.rounds}/${BABYSIT_MAX_ROUNDS})`,
            description: "Fix rounds stop; the pull request is left as it is",
            icon: "stop.circle",
          },
    );
  }
  return items;
}

/** "Babysitting r/10" while the thread is babysat (#269 A), for the thread
    list row and the header menu's status line; null while off. */
export function babysitLabel(babysit: ThreadBabysit | null | undefined): string | null {
  return babysit == null ? null : `Babysitting ${babysit.rounds}/${BABYSIT_MAX_ROUNDS}`;
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
