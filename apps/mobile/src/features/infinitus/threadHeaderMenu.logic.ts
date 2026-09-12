/** One choice of the thread header's menu; `id` is the Android menu's event
    key, so it is unique across the menu. */
export interface ThreadMenuAction {
  readonly id: string;
  readonly label: string;
  readonly description?: string;
  /** An SF Symbol name; Android maps it through `AppSymbol`. */
  readonly icon: string;
  readonly disabled?: boolean;
  readonly onPress: () => void;
}

export interface ThreadMenuPullRequest {
  readonly number: number;
  /** The link's accessibility label, "#12 pull request, checks failing". */
  readonly status: string;
  /** The phase line and the actions, in the order the menu lists them. */
  readonly actions: ReadonlyArray<ThreadMenuAction>;
}

export interface ThreadHeaderMenuModel {
  /** SF Symbol name of the one header button. */
  readonly icon: string;
  /** The PR's "#12" beside the icon, else nothing. */
  readonly label: string | null;
  readonly accessibilityLabel: string;
  readonly title: string | undefined;
  readonly actions: ReadonlyArray<ThreadMenuAction>;
}

export const PR_ICON = "arrow.triangle.pull";
export const MENU_ICON = "ellipsis.circle";

/**
 * Fork (#941 walk, after #908): the thread header's Infinitus choices — the
 * pull request's phase and actions, "Ask a side question", "Thread usage" —
 * as ONE menu button, so the compact iOS header keeps upstream's three git
 * buttons visible instead of collapsing everything into "…". A thread with
 * a pull request keeps the PR's icon and "#N" on the button, its choices
 * first; without one the button is the plain "more" circle. Null when there
 * is nothing to offer.
 */
export function threadHeaderMenu(input: {
  readonly pullRequest: ThreadMenuPullRequest | null;
  readonly threadActions: ReadonlyArray<ThreadMenuAction>;
}): ThreadHeaderMenuModel | null {
  const { pullRequest, threadActions } = input;
  const actions = [...(pullRequest?.actions ?? []), ...threadActions];
  if (actions.length === 0) return null;
  if (pullRequest === null) {
    return {
      icon: MENU_ICON,
      label: null,
      accessibilityLabel: "Thread actions",
      title: undefined,
      actions,
    };
  }
  return {
    icon: PR_ICON,
    label: `#${pullRequest.number}`,
    accessibilityLabel:
      threadActions.length === 0
        ? `Pull request ${pullRequest.status}`
        : `Pull request ${pullRequest.status}, and thread actions`,
    title: `Pull request #${pullRequest.number}`,
    actions,
  };
}
