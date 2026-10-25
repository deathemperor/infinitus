/**
 * A checkout that only carries upstream's `t3.json` still works: the names in
 * `T3_PROJECT_FILE_NAMES` are tried in order and the first one that exists
 * decides, so a repository never has to be converted to be read.
 */
import * as Context from "effect/Context";
import * as Effect from "effect/Effect";
import * as FileSystem from "effect/FileSystem";
import * as Layer from "effect/Layer";
import * as Option from "effect/Option";
import * as Path from "effect/Path";
import * as Schema from "effect/Schema";

import { T3_PROJECT_FILE_NAMES, type T3ProjectFile } from "@infinitus/contracts";
import { T3ProjectFileFromJson } from "@infinitus/shared/t3ProjectFile";

const decodeT3ProjectFileJson = Schema.decodeEffect(T3ProjectFileFromJson);

export class T3ProjectFileLoadError extends Schema.TaggedError<T3ProjectFileLoadError>()(
  "T3ProjectFileLoadError",
  {
    operation: Schema.Literals(["read", "decode"]),
    workspaceRoot: Schema.String,
    filePath: Schema.String,
    cause: Schema.Defect(),
  },
) {
  override get message(): string {
    return `Failed to ${this.operation} the project file at ${this.filePath}.`;
  }
}

export class T3ProjectFileLoader extends Context.Service<
  T3ProjectFileLoader,
  {
<<<<<<< HEAD
    /**
     * Prefers `infinitus.json` over upstream's `t3.json`. Never fails: missing, unreadable, or
     * invalid files resolve to `Option.none` (invalid files are logged as warnings).
     */
=======
    /** Never fails; missing/unreadable/invalid files return none, with warnings for invalid files. */
>>>>>>> upstream-sync-5398be0d4-upstream-renamed
    readonly load: (workspaceRoot: string) => Effect.Effect<Option.Option<T3ProjectFile>>;
  }
>()("t3/project/T3ProjectFileLoader") {}

const logT3ProjectFileLoadError = (error: T3ProjectFileLoadError) =>
  Effect.logWarning(error).pipe(
    Effect.annotateLogs({
      operation: error.operation,
      workspaceRoot: error.workspaceRoot,
      filePath: error.filePath,
      errorTag: error._tag,
    }),
  );

/** @public */
export const make = Effect.gen(function* () {
  const fileSystem = yield* FileSystem.FileSystem;
  const path = yield* Path.Path;

  const load: T3ProjectFileLoader["Service"]["load"] = Effect.fn("T3ProjectFileLoader.load")(
    function* (workspaceRoot) {
      for (const fileName of T3_PROJECT_FILE_NAMES) {
        const filePath = path.join(workspaceRoot, fileName);
        const raw = yield* fileSystem.readFileString(filePath).pipe(
          Effect.asSome,
          Effect.catchTags({
            PlatformError: (error) =>
              error.reason._tag === "NotFound"
                ? Effect.succeed(Option.none<string>())
                : logT3ProjectFileLoadError(
                    new T3ProjectFileLoadError({
                      operation: "read",
                      workspaceRoot,
                      filePath,
                      cause: error,
                    }),
                  ).pipe(Effect.as(Option.none<string>())),
          }),
        );
        // A name that is absent (or unreadable) leaves the next one its turn;
        // one that answered decides, broken or not, so a checkout carrying
        // both files never silently falls back to the older one.
        if (Option.isNone(raw)) continue;
        return yield* decodeT3ProjectFileJson(raw.value).pipe(
          Effect.asSome,
          Effect.catchTags({
            SchemaError: (error) =>
              logT3ProjectFileLoadError(
                new T3ProjectFileLoadError({
                  operation: "decode",
                  workspaceRoot,
                  filePath,
                  cause: error,
                }),
              ).pipe(Effect.as(Option.none<T3ProjectFile>())),
          }),
        );
      }
      return Option.none<T3ProjectFile>();
    },
  );

  return T3ProjectFileLoader.of({ load });
});

export const layer = Layer.effect(T3ProjectFileLoader, make);
