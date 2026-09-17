import { InfinitusCommandFailed, InfinitusUnavailable } from "@infinitus/contracts/infinitus";
import { it as effectIt } from "@effect/vitest";
import * as Effect from "effect/Effect";
import { describe, expect, it } from "vite-plus/test";

import {
  signInPartition,
  signInUserAgent,
  signInWindowOpenAction,
  signInWindowOptions,
  submitSignInCode,
} from "./InfinitusSignIn.ts";

const input = { flowId: "flow-1", url: "https://claude.ai/oauth", label: "Add account" };

describe("signInWindowOptions", () => {
  it("gives every flow its own in-memory jar and nothing of ours in the page", () => {
    const options = signInWindowOptions(input, "darwin");
    expect(options.webPreferences?.partition).toBe("signin-flow-1");
    expect(signInPartition("x")).not.toMatch(/^persist:/);
    expect(options.webPreferences).toMatchObject({
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
      webviewTag: false,
    });
    expect(options.webPreferences?.preload).toBeUndefined();
    expect(options.title).toBe("Add account — Infinitus");
  });
});

describe("signInUserAgent", () => {
  it("leaves Chromium's own products and drops the ones that say this is an app", () => {
    const chrome =
      "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/142.0.0.0 Safari/537.36";
    const electron =
      "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Infinitus/0.5.0-alpha.22 Chrome/142.0.0.0 Electron/44.1.0 Safari/537.36";
    expect(signInUserAgent(electron)).toBe(chrome);
    expect(signInUserAgent(chrome)).toBe(chrome);
  });
});

describe("signInWindowOpenAction", () => {
  it("opens a page in a pop-up and refuses anything that is not one", () => {
    expect(signInWindowOpenAction({ url: "https://accounts.google.com/o/oauth2/v2/auth" })).toBe(
      "popup",
    );
    expect(signInWindowOpenAction({ url: "file:///etc/passwd" })).toBe("deny");
    expect(signInWindowOpenAction({ url: "infinitus://open" })).toBe("deny");
  });
});

describe("submitSignInCode", () => {
  effectIt.effect("sends the code as the request's secret, never as an argument", () =>
    Effect.gen(function* () {
      const seen: Array<{ command: string; args?: ReadonlyArray<string>; secret?: string }> = [];
      const result = yield* submitSignInCode(
        (request) => {
          seen.push(request);
          return Effect.succeed({ ok: true });
        },
        { flowId: "flow-1", code: "  abc#state \n" },
      );
      expect(result).toEqual({ ok: true });
      expect(seen).toEqual([{ command: "signin-code", args: ["flow-1"], secret: "abc#state" }]);
    }),
  );

  effectIt.effect("hands back the app's own rejection, and says when the app is away", () =>
    Effect.gen(function* () {
      const refused = yield* submitSignInCode(
        () =>
          Effect.fail(
            new InfinitusCommandFailed({
              command: "signin-code",
              error: "Invalid code. Please try again.",
              restarting: false,
            }),
          ),
        { flowId: "flow-1", code: "nope" },
      );
      expect(refused).toEqual({ ok: false, error: "Invalid code. Please try again." });
      const away = yield* submitSignInCode(
        () => Effect.fail(new InfinitusUnavailable({ path: "/tmp/x.sock", cause: "ECONNREFUSED" })),
        { flowId: "flow-1", code: "abc" },
      );
      expect(away).toEqual({ ok: false, error: "Infinitus is not running on this Mac." });
      const empty = yield* submitSignInCode(() => Effect.die("never called"), {
        flowId: "flow-1",
        code: "   ",
      });
      expect(empty.ok).toBe(false);
    }),
  );
});
