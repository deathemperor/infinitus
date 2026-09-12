import { describe, expect, it } from "vite-plus/test";

import {
  MENU_ICON,
  PR_ICON,
  threadHeaderMenu,
  type ThreadMenuAction,
} from "./threadHeaderMenu.logic";

const action = (id: string, label = id): ThreadMenuAction => ({
  id,
  label,
  icon: "circle",
  onPress: () => {},
});

describe("threadHeaderMenu (#941)", () => {
  it("is nothing when the thread offers nothing", () => {
    expect(threadHeaderMenu({ pullRequest: null, threadActions: [] })).toBeNull();
  });

  it("is the plain more button carrying the thread's choices without a pull request", () => {
    const menu = threadHeaderMenu({
      pullRequest: null,
      threadActions: [action("side-question", "Ask a side question"), action("usage")],
    });
    expect(menu?.icon).toBe(MENU_ICON);
    expect(menu?.label).toBeNull();
    expect(menu?.title).toBeUndefined();
    expect(menu?.accessibilityLabel).toBe("Thread actions");
    expect(menu?.actions.map((entry) => entry.id)).toEqual(["side-question", "usage"]);
  });

  it("keeps the pull request's icon, number and choices first when there is one", () => {
    const menu = threadHeaderMenu({
      pullRequest: {
        number: 12,
        status: "#12 pull request, checks failing",
        actions: [action("phase", "Checks failing"), action("open", "Open pull request")],
      },
      threadActions: [action("usage", "Thread usage")],
    });
    expect(menu?.icon).toBe(PR_ICON);
    expect(menu?.label).toBe("#12");
    expect(menu?.title).toBe("Pull request #12");
    expect(menu?.accessibilityLabel).toBe(
      "Pull request #12 pull request, checks failing, and thread actions",
    );
    expect(menu?.actions.map((entry) => entry.id)).toEqual(["phase", "open", "usage"]);
  });

  it("reads as the pull request alone when the thread adds nothing", () => {
    const menu = threadHeaderMenu({
      pullRequest: { number: 3, status: "#3 pull request", actions: [action("open")] },
      threadActions: [],
    });
    expect(menu?.accessibilityLabel).toBe("Pull request #3 pull request");
  });
});
