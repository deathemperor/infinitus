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
  it("a left swipe goes back on a backable page and nowhere else", () => {
    expect(swipeHistoryIntent("left", "/settings/general")).toBe("back");
    expect(swipeHistoryIntent("left", "/env-1/thread-1")).toBeNull();
  });

  it("a right swipe goes forward anywhere", () => {
    expect(swipeHistoryIntent("right", "/env-1/thread-1")).toBe("forward");
    expect(swipeHistoryIntent("right", "/accounts")).toBe("forward");
  });

  it("matches the mouse buttons on the same page", () => {
    // The driver sends the back button as a gesture (#1250); both paths must
    // agree on what the back button does.
    for (const pathname of ["/settings/general", "/env-1/thread-1", "/accounts"]) {
      expect(swipeHistoryIntent("left", pathname), pathname).toBe(
        mouseHistoryIntent(3, pathname),
      );
      expect(swipeHistoryIntent("right", pathname), pathname).toBe(
        mouseHistoryIntent(4, pathname),
      );
    }
  });
});
