import { InfinitusCommandFailed, InfinitusUnavailable } from "@t3tools/contracts/infinitus";
import { it as effectIt } from "@effect/vitest";
import * as Effect from "effect/Effect";
import { describe, expect, it } from "vite-plus/test";

import { signInPartition, signInWindowOptions, submitSignInCode } from "./InfinitusSignIn.ts";

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
