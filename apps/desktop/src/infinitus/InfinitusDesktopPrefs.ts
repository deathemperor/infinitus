/**
 * The desktop shell's own Infinitus knobs (#654, one-app feel), kept in
 * `<stateDir>/infinitus-desktop.json` next to `desktop-settings.json` rather
 * than inside it: this is fork state, and the upstream settings document
 * stays byte-for-byte upstream's.
 */
import { InfinitusDesktopPrefs as InfinitusDesktopPrefsSchema } from "@t3tools/contracts/infinitus";
import * as Context from "effect/Context";
import * as Effect from "effect/Effect";
import * as FileSystem from "effect/FileSystem";
import * as Layer from "effect/Layer";
import * as Path from "effect/Path";
import * as Schema from "effect/Schema";
import * as SynchronizedRef from "effect/SynchronizedRef";

import * as DesktopEnvironment from "../app/DesktopEnvironment.ts";

export type InfinitusDesktopPrefs = typeof InfinitusDesktopPrefsSchema.Type;

export const DEFAULT_INFINITUS_DESKTOP_PREFS: InfinitusDesktopPrefs = {
  quitInfinitusWithApp: false,
};

const INFINITUS_DESKTOP_PREFS_FILE = "infinitus-desktop.json";

/** Every key optional on disk: a file from a build that knew fewer knobs, or a
    hand edit that dropped one, still reads. */
const PrefsDocument = Schema.Struct({
  quitInfinitusWithApp: Schema.optionalKey(Schema.Boolean),
});
const decodeDocument = Schema.decodeUnknownSync(Schema.fromJsonString(PrefsDocument));
const encodeDocument = Schema.encodeSync(Schema.fromJsonString(PrefsDocument));

/** What a file's text means; anything unreadable is the defaults. */
export function decodeInfinitusDesktopPrefs(raw: string | null): InfinitusDesktopPrefs {
  if (raw === null) return DEFAULT_INFINITUS_DESKTOP_PREFS;
  try {
    const parsed = decodeDocument(raw);
    return { quitInfinitusWithApp: parsed.quitInfinitusWithApp === true };
  } catch {
    return DEFAULT_INFINITUS_DESKTOP_PREFS;
  }
}

export function encodeInfinitusDesktopPrefs(prefs: InfinitusDesktopPrefs): string {
  return `${encodeDocument(prefs)}\n`;
}

export class InfinitusDesktopPrefsWriteError extends Schema.TaggedError<InfinitusDesktopPrefsWriteError>()(
  "InfinitusDesktopPrefsWriteError",
  { path: Schema.String, cause: Schema.Defect() },
) {
  override get message(): string {
    return `Failed to write the Infinitus desktop prefs at ${this.path}.`;
  }
}

export class InfinitusDesktopPrefsService extends Context.Service<
  InfinitusDesktopPrefsService,
  {
    readonly get: Effect.Effect<InfinitusDesktopPrefs>;
    readonly setQuitWithApp: (
      enabled: boolean,
    ) => Effect.Effect<InfinitusDesktopPrefs, InfinitusDesktopPrefsWriteError>;
  }
>()("@t3tools/desktop/infinitus/InfinitusDesktopPrefs/InfinitusDesktopPrefsService") {}

const make = Effect.gen(function* () {
  const environment = yield* DesktopEnvironment.DesktopEnvironment;
  const fileSystem = yield* FileSystem.FileSystem;
  const path = yield* Path.Path;
  const prefsPath = path.join(environment.stateDir, INFINITUS_DESKTOP_PREFS_FILE);

  const initial = yield* fileSystem.readFileString(prefsPath).pipe(
    Effect.orElseSucceed((): string | null => null),
    Effect.map(decodeInfinitusDesktopPrefs),
  );
  const ref = yield* SynchronizedRef.make(initial);

  // Temp file then rename, as desktop-settings.json is written: a crash
  // mid-write leaves the previous file, never a half one.
  const write = (prefs: InfinitusDesktopPrefs) =>
    Effect.gen(function* () {
      const tempPath = `${prefsPath}.${process.pid}.tmp`;
      yield* fileSystem.makeDirectory(environment.stateDir, { recursive: true });
      yield* fileSystem.writeFileString(tempPath, encodeInfinitusDesktopPrefs(prefs));
      yield* fileSystem.rename(tempPath, prefsPath);
    }).pipe(
      Effect.mapError((cause) => new InfinitusDesktopPrefsWriteError({ path: prefsPath, cause })),
    );

  return InfinitusDesktopPrefsService.of({
    get: SynchronizedRef.get(ref),
    setQuitWithApp: (enabled) =>
      SynchronizedRef.updateAndGetEffect(ref, (prefs) => {
        if (prefs.quitInfinitusWithApp === enabled) return Effect.succeed(prefs);
        const next: InfinitusDesktopPrefs = { ...prefs, quitInfinitusWithApp: enabled };
        return write(next).pipe(Effect.as(next));
      }),
  });
});

export const layer = Layer.effect(InfinitusDesktopPrefsService, make);
