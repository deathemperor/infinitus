import type { SignInRowModel } from "@t3tools/client-runtime/state/infinitusAccounts";
import { afterEach, beforeEach, describe, expect, it, vi } from "vite-plus/test";

import { signInButtonLabel, signInStatus, waitingSessionsLabel } from "./signIns.logic";

const row = (overrides: Partial<SignInRowModel> = {}): SignInRowModel => ({
  key: "aws:dev",
  tool: "aws",
  toolLabel: "AWS",
  profile: "dev",
  failedAt: "2026-09-10T08:00:00Z",
  sessions: [],
  pid: 101,
  deviceCode: true,
  phase: "idle",
  url: null,
  userCode: null,
  message: null,
  ...overrides,
});

describe("signInStatus", () => {
  beforeEach(() => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date("2026-09-10T10:15:00Z"));
  });
  afterEach(() => {
    vi.useRealTimers();
  });

  it("says how long an idle profile has been lapsed", () => {
    expect(signInStatus(row())).toBe("Lapsed 2h ago");
    expect(signInStatus(row({ failedAt: null }))).toBe("Lapsed");
    expect(signInStatus(row({ failedAt: "not a date" }))).toBe("Lapsed");
  });

  it("follows the running login", () => {
    expect(signInStatus(row({ phase: "starting" }))).toBe("Starting sign-in…");
    expect(
      signInStatus(
        row({ phase: "waiting", url: "https://device.sso.example/", userCode: "ABCD-EFGH" }),
      ),
    ).toBe("Open the sign-in page and enter ABCD-EFGH");
    expect(signInStatus(row({ phase: "waiting" }))).toBe("Waiting for the sign-in page…");
    expect(signInStatus(row({ phase: "waiting", deviceCode: false }))).toBe(
      "Waiting for the Mac's browser…",
    );
    expect(signInStatus(row({ phase: "done" }))).toBe("Signed in");
    expect(signInStatus(row({ phase: "failed" }))).toBe("Sign-in failed");
    expect(signInStatus(row({ phase: "failed", message: "refused" }))).toBe(
      "Sign-in failed: refused",
    );
  });
});

describe("row text", () => {
  it("lists the waiting sessions", () => {
    expect(waitingSessionsLabel([])).toBe("");
    expect(waitingSessionsLabel(["api", "web"])).toBe("Waiting: api, web");
  });

  it("offers the button only when nothing is running", () => {
    expect(signInButtonLabel(row())).toBe("Sign in");
    expect(signInButtonLabel(row({ phase: "failed" }))).toBe("Try again");
    expect(signInButtonLabel(row({ phase: "starting" }))).toBeNull();
    expect(signInButtonLabel(row({ phase: "waiting" }))).toBeNull();
    expect(signInButtonLabel(row({ phase: "done" }))).toBeNull();
  });
});
