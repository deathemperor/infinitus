import { describe, expect, it } from "vite-plus/test";

import { menuBarAppVersionLine } from "./panel.logic";

const status = {
  version: "0.5.0-alpha.7",
  sha: "1d90390896715b810be7c307d56ee8ec6bb50cd5",
  socket: "/tmp/x.sock",
  badge: "",
  playground: false,
  signInRunning: false,
  engines: {},
};

describe("menuBarAppVersionLine", () => {
  it("names the version and a short sha", () => {
    expect(menuBarAppVersionLine(status)).toBe("Menu bar app 0.5.0-alpha.7 (1d90390896)");
  });

  it("drops the parenthesis for a source build with no sha", () => {
    expect(menuBarAppVersionLine({ ...status, sha: "" })).toBe("Menu bar app 0.5.0-alpha.7");
  });

  it("is absent until the app answered", () => {
    expect(menuBarAppVersionLine(undefined)).toBeUndefined();
  });
});
