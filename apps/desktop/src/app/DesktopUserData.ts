import * as Effect from "effect/Effect";
import * as Path from "effect/Path";
import * as PlatformError from "effect/PlatformError";
import * as Schema from "effect/Schema";

import {
  DESKTOP_DEV_USER_DATA_DIR_NAME,
  DESKTOP_USER_DATA_DIR_NAME,
} from "@infinitus/shared/desktopIdentity";

export class DesktopUserDataInitializationError extends Schema.TaggedError<DesktopUserDataInitializationError>()(
  "DesktopUserDataInitializationError",
  {
    operation: Schema.Literals(["inspect", "read", "create-directory", "write"]),
    resourcePath: Schema.String,
    category: Schema.String,
    cause: Schema.Defect(),
  },
) {
  override get message() {
    return `Could not initialize Electron user data during ${this.operation} at ${this.resourcePath} (${this.category}).`;
  }

  static fromFileSystem(
    cause: PlatformError.PlatformError,
    operation: DesktopUserDataInitializationError["operation"],
    resourcePath: string,
  ) {
    return new DesktopUserDataInitializationError({
      operation,
      resourcePath,
      category: cause.reason._tag,
      cause,
    });
  }
}

/**
 * Select Electron's profile independently of the server's home directory. Fork: the
 * directory is the fork's own and no legacy one is probed or seeded; upstream's
 * `T3 Code (Alpha)` / `t3code` profiles belong to the installed T3 Code app.
 */
export const resolveUserDataPath = Effect.fn("desktop.userData.resolveUserDataPath")(
  function* (input: {
    readonly appDataDirectory: string;
    readonly isDevelopment: boolean;
    readonly platform: NodeJS.Platform;
  }) {
    const path = yield* Path.Path;
    return path.join(
      input.appDataDirectory,
      input.isDevelopment ? DESKTOP_DEV_USER_DATA_DIR_NAME : DESKTOP_USER_DATA_DIR_NAME,
    );
  },
);
