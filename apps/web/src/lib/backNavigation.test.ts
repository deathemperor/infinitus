import { describe, expect, it } from "vite-plus/test";

import { isBackablePathname, mouseHistoryIntent, swipeHistoryIntent } from "./backNavigation";

describe("isBackablePathname", () => {
  it("matches the pages whose header shows the back arrow", () => {
    for (const pathname of [
      "/settings",
      "/settings/general",
      "/settings/infinitus/lock",
      "/projects/abc",
      "/projects/abc/",
      "/usage",
      "/pull-requests",
      "/accounts",
      "/stats",
      "/activity",
      "/utilization",
    ]) {
      expect(isBackablePathname(pathname), pathname).toBe(true);
    }
  });

  it("leaves threads, drafts and unknown pages alone", () => {
    for (const pathname of [
      "/",
      "/threads/t1",
      "/projects/abc/threads/t1",
      "/settingsx",
      "/usage/extra",
      "/team",
    ]) {
      expect(isBackablePathname(pathname), pathname).toBe(false);
    }
  });
});

describe("mouseHistoryIntent", () => {
  it("goes back only on a backable page", () => {
    expect(mouseHistoryIntent(3, "/settings/general")).toBe("back");
    expect(mouseHistoryIntent(3, "/threads/t1")).toBeNull();
  });

  it("goes forward anywhere and ignores the other buttons", () => {
    expect(mouseHistoryIntent(4, "/threads/t1")).toBe("forward");
    expect(mouseHistoryIntent(0, "/settings")).toBeNull();
    expect(mouseHistoryIntent(1, "/settings")).toBeNull();
    expect(mouseHistoryIntent(2, "/settings")).toBeNull();
  });
});

describe("swipeHistoryIntent", () => {
  it("a right swipe goes back on a backable page and nowhere else", () => {
    expect(swipeHistoryIntent("right", "/settings/general")).toBe("back");
    expect(swipeHistoryIntent("right", "/env-1/thread-1")).toBeNull();
  });

  it("a left swipe goes forward anywhere", () => {
    expect(swipeHistoryIntent("left", "/env-1/thread-1")).toBe("forward");
    expect(swipeHistoryIntent("left", "/accounts")).toBe("forward");
  });
});
