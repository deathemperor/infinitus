import * as NodeServices from "@effect/platform-node/NodeServices";
import { assert, it } from "@effect/vitest";
import * as Effect from "effect/Effect";
import * as FileSystem from "effect/FileSystem";

import { resolveUserDataPath } from "./DesktopUserData.ts";

/** The fork never adopts or seeds from the installed T3 Code app's profile:
    an existing `T3 Code (Alpha)` beside the fork's directory is left alone,
    and no filesystem call is made to find out whether it exists. */
it.effect.each([
  { isDevelopment: false, platform: "win32" as const, expected: "/profiles/infinitus-desktop" },
  { isDevelopment: false, platform: "darwin" as const, expected: "/profiles/infinitus-desktop" },
  { isDevelopment: true, platform: "darwin" as const, expected: "/profiles/infinitus-desktop-dev" },
])("resolves the fork's own profile without probing a legacy one (%o)", (input) =>
  Effect.gen(function* () {
    const resolved = yield* resolveUserDataPath({
      appDataDirectory: "/profiles",
      isDevelopment: input.isDevelopment,
      platform: input.platform,
    });
    assert.equal(resolved, input.expected);
  }).pipe(
    Effect.provideService(
      FileSystem.FileSystem,
      FileSystem.makeNoop({
        exists: () => Effect.die(new Error("the legacy profile must never be probed")),
      }),
    ),
    Effect.provide(NodeServices.layer),
  ),
);
