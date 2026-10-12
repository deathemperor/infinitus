import { describe, expect, it } from "vite-plus/test";

import {
  resolveDeepLinkProject,
  settingsDeepLinkTarget,
  workspaceRootBasename,
} from "./deepLink.logic";

const projects = [
  { id: "p1", title: "Infinitus", workspaceRoot: "/Users/me/death/limitless" },
  { id: "p2", title: "Fork", workspaceRoot: "/Users/me/death/limitless-t3i/" },
  { id: "p3", title: "limitless", workspaceRoot: "C:\\code\\other" },
];

describe("resolveDeepLinkProject (#270 D)", () => {
  it("matches by id, then title, then the workspace folder, case-insensitively", () => {
    expect(resolveDeepLinkProject(projects, "p2")?.id).toBe("p2");
    expect(resolveDeepLinkProject(projects, "infinitus")?.id).toBe("p1");
    expect(resolveDeepLinkProject(projects, "LIMITLESS-T3I")?.id).toBe("p2");
    // A title beats a folder of the same name.
    expect(resolveDeepLinkProject(projects, "limitless")?.id).toBe("p3");
    expect(resolveDeepLinkProject(projects, "other")?.id).toBe("p3");
  });

  it("finds nothing for a blank or unknown key", () => {
    expect(resolveDeepLinkProject(projects, "  ")).toBeNull();
    expect(resolveDeepLinkProject(projects, "nope")).toBeNull();
    expect(resolveDeepLinkProject([], "p1")).toBeNull();
  });
});

describe("workspaceRootBasename", () => {
  it("takes the last non-empty segment on either separator", () => {
    expect(workspaceRootBasename("/a/b/c/")).toBe("c");
    expect(workspaceRootBasename("C:\\x\\y")).toBe("y");
    expect(workspaceRootBasename("")).toBe("");
  });
});

describe("settingsDeepLinkTarget", () => {
  it("opens a listed section and refuses any other path", () => {
    expect(settingsDeepLinkTarget("/settings/engines")).toBe("/settings/engines");
    expect(settingsDeepLinkTarget("/settings/nowhere")).toBeNull();
  });

  it("lands an older menu bar app's retired Infinitus group on the page's new route", () => {
    expect(settingsDeepLinkTarget("/settings/infinitus")).toBe("/settings/menu-bar");
    expect(settingsDeepLinkTarget("/settings/infinitus/engines")).toBe("/settings/engines");
    expect(settingsDeepLinkTarget("/settings/infinitus/sessions")).toBe("/settings/priority");
  });
});
