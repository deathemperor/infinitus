import * as NodeServices from "@effect/platform-node/NodeServices";
import { assert, it } from "@effect/vitest";
import { DESKTOP_USER_DATA_DIR_NAME } from "@infinitus/shared/desktopIdentity";
import * as Effect from "effect/Effect";
import * as FileSystem from "effect/FileSystem";
import * as Path from "effect/Path";

import * as DesktopPreReadyFileSystem from "./DesktopPreReadyFileSystem.ts";
import * as DesktopUserData from "./DesktopUserData.ts";

const resolveWindowsUserData = (appDataDirectory: string) =>
  DesktopUserData.resolveUserDataPath({
    appDataDirectory,
    isDevelopment: false,
    platform: "win32",
  }).pipe(Effect.provide(DesktopPreReadyFileSystem.layer));

it.layer(NodeServices.layer)("DesktopPreReadyFileSystem", (it) => {
  // Fork: upstream seeds its Windows profile from the pre-rename "T3 Code
  // (Alpha)" state here; the fork keeps its own directory and copies nothing.
  it.effect("keeps the fork's own Windows profile and never seeds it from a legacy one", () =>
    Effect.gen(function* () {
      const fileSystem = yield* FileSystem.FileSystem;
      const path = yield* Path.Path;
      const root = yield* fileSystem.makeTempDirectoryScoped({ prefix: "t3-pre-ready-fs-" });
      yield* fileSystem.makeDirectory(path.join(root, "T3 Code (Alpha)"));
      yield* fileSystem.writeFileString(path.join(root, "T3 Code (Alpha)", "Local State"), "keys");

      const userData = yield* resolveWindowsUserData(root);

      assert.equal(userData, path.join(root, DESKTOP_USER_DATA_DIR_NAME));
      assert.isFalse(yield* fileSystem.exists(path.join(userData, "Local State")));
    }),
  );
});
