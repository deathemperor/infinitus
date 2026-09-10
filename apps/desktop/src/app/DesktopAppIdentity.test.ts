import * as NodePath from "@effect/platform-node/NodePath";
import * as NodeServices from "@effect/platform-node/NodeServices";
import { assert, describe, it } from "@effect/vitest";
import * as Effect from "effect/Effect";
import * as FileSystem from "effect/FileSystem";
import * as Layer from "effect/Layer";
import * as Option from "effect/Option";
import * as PlatformError from "effect/PlatformError";

import type * as Electron from "electron";

import * as ElectronApp from "../electron/ElectronApp.ts";
import * as DesktopAppIdentity from "./DesktopAppIdentity.ts";
import * as DesktopAssets from "./DesktopAssets.ts";
import * as DesktopConfig from "./DesktopConfig.ts";
import * as DesktopEnvironment from "./DesktopEnvironment.ts";

const defaultEnvironmentInput = {
  dirname: "/repo/apps/desktop/dist-electron",
  homeDirectory: "/Users/alice",
  platform: "darwin",
  processArch: "arm64",
  appVersion: "1.2.3",
  appPath: "/Applications/T3 Code.app/Contents/Resources/app.asar",
  isPackaged: true,
  resourcesPath: "/Applications/T3 Code.app/Contents/Resources",
  runningUnderArm64Translation: false,
} satisfies DesktopEnvironment.MakeDesktopEnvironmentInput;

type TestEnvironmentInput = Partial<DesktopEnvironment.MakeDesktopEnvironmentInput> & {
  readonly env?: Record<string, string | undefined>;
};

interface ElectronAppCalls {
  readonly setAboutPanelOptions: Array<Electron.AboutPanelOptionsOptions>;
  readonly setDockIcon: string[];
  readonly setName: string[];
}

const makeElectronAppLayer = (calls: ElectronAppCalls) =>
  Layer.succeed(ElectronApp.ElectronApp, {
    metadata: Effect.die("unexpected metadata read"),
    name: Effect.succeed("T3 Code"),
    systemLocale: Effect.succeed("en-US"),
    whenReady: Effect.void,
    quit: Effect.void,
    exit: () => Effect.void,
    relaunch: () => Effect.void,
    setPath: () => Effect.void,
    setName: (name) =>
      Effect.sync(() => {
        calls.setName.push(name);
      }),
    setAboutPanelOptions: (options) =>
      Effect.sync(() => {
        calls.setAboutPanelOptions.push(options);
      }),
    setAppUserModelId: () => Effect.void,
    getAppMetrics: Effect.succeed([]),
    isDefaultProtocolClient: () => Effect.succeed(false),
    setAsDefaultProtocolClient: () => Effect.succeed(true),
    setDesktopName: () => Effect.void,
    setDockIcon: (iconPath) =>
      Effect.sync(() => {
        calls.setDockIcon.push(iconPath);
      }),
    appendCommandLineSwitch: () => Effect.void,
    onBeforeQuitForUpdate: () => Effect.void,
    removeCommandLineSwitch: () => Effect.void,
    on: () => Effect.void,
  } satisfies ElectronApp.ElectronApp["Service"]);

const makeAssetsLayer = (png: Option.Option<string>) =>
  Layer.succeed(DesktopAssets.DesktopAssets, {
    iconPaths: Effect.succeed({
      ico: Option.none(),
      icns: Option.none(),
      png,
    }),
    resolveResourcePath: () => Effect.succeed(Option.none()),
  } satisfies DesktopAssets.DesktopAssets["Service"]);

const makeEnvironmentLayer = (overrides: TestEnvironmentInput = {}, adoptsLegacy = false) => {
  const { env, ...environmentOverrides } = overrides;
  const layer = DesktopEnvironment.layer({
    ...defaultEnvironmentInput,
    ...environmentOverrides,
  }).pipe(
    Layer.provide(
      Layer.mergeAll(
        NodeServices.layer,
        NodePath.layerPosix,
        DesktopConfig.layerTest({
          ...env,
        }),
      ),
    ),
  );
  if (!adoptsLegacy) return layer;
  // The fork adopts no legacy directory, so only a patched environment can
  // still exercise upstream's adoption branch.
  return Layer.effect(
    DesktopEnvironment.DesktopEnvironment,
    Effect.gen(function* () {
      const environment = yield* DesktopEnvironment.DesktopEnvironment;
      return DesktopEnvironment.DesktopEnvironment.of({
        ...environment,
        adoptsLegacyUserDataDir: true,
      });
    }),
  ).pipe(Layer.provide(layer));
};

const withIdentity = <A, E, R>(
  effect: Effect.Effect<
    A,
    E,
    | R
    | DesktopAppIdentity.DesktopAppIdentity
    | DesktopEnvironment.DesktopEnvironment
    | FileSystem.FileSystem
  >,
  input: {
    readonly calls?: ElectronAppCalls;
    readonly environment?: TestEnvironmentInput;
    readonly adoptsLegacyUserDataDir?: boolean;
    readonly legacyPathExists?: boolean;
    readonly legacyPathProbeError?: PlatformError.PlatformError;
    readonly packageJson?: string;
    readonly pngIconPath?: Option.Option<string>;
  } = {},
) => {
  const calls: ElectronAppCalls = input.calls ?? {
    setAboutPanelOptions: [],
    setDockIcon: [],
    setName: [],
  };

  return effect.pipe(
    Effect.provide(
      DesktopAppIdentity.layer.pipe(
        Layer.provideMerge(
          FileSystem.layerNoop({
            exists: (path) =>
              input.legacyPathProbeError
                ? Effect.fail(input.legacyPathProbeError)
                : Effect.succeed(
                    input.legacyPathExists === true && path.includes("T3 Code (Alpha)"),
                  ),
            readFileString: () =>
              Effect.succeed(input.packageJson ?? '{"t3codeCommitHash":"abcdef1234567890"}'),
          }),
        ),
        Layer.provideMerge(makeAssetsLayer(input.pngIconPath ?? Option.none())),
        Layer.provideMerge(makeElectronAppLayer(calls)),
        Layer.provideMerge(
          makeEnvironmentLayer(input.environment, input.adoptsLegacyUserDataDir === true),
        ),
      ),
    ),
  );
};

describe("DesktopAppIdentity", () => {
  it.effect("never adopts the installed T3 Code's userData directory", () =>
    withIdentity(
      Effect.gen(function* () {
        const identity = yield* DesktopAppIdentity.DesktopAppIdentity;
        const userDataPath = yield* identity.resolveUserDataPath;

        // "T3 Code (Alpha)" exists on this machine — it is the app the user
        // runs every day, lock and cookies included. The fork keeps its own.
        assert.equal(userDataPath, "/Users/alice/Library/Application Support/infinitus");
      }),
      { legacyPathExists: true },
    ),
  );

  it.effect("keeps a development run in its own userData directory", () =>
    withIdentity(
      Effect.gen(function* () {
        const identity = yield* DesktopAppIdentity.DesktopAppIdentity;
        const userDataPath = yield* identity.resolveUserDataPath;

        assert.equal(userDataPath, "/Users/alice/Library/Application Support/infinitus-dev");
      }),
      {
        environment: { env: { VITE_DEV_SERVER_URL: "http://localhost:5173" } },
        legacyPathExists: true,
      },
    ),
  );

  it.effect("still adopts a legacy directory a build does claim", () =>
    withIdentity(
      Effect.gen(function* () {
        const identity = yield* DesktopAppIdentity.DesktopAppIdentity;
        const userDataPath = yield* identity.resolveUserDataPath;

        assert.equal(userDataPath, "/Users/alice/Library/Application Support/T3 Code (Alpha)");
      }),
      { adoptsLegacyUserDataDir: true, legacyPathExists: true },
    ),
  );

  it.effect("preserves failures while inspecting the legacy userData path", () => {
    const legacyPath = "/Users/alice/Library/Application Support/T3 Code (Alpha)";
    const cause = PlatformError.systemError({
      _tag: "PermissionDenied",
      module: "FileSystem",
      method: "exists",
      description: "permission denied",
      pathOrDescriptor: legacyPath,
    });

    return withIdentity(
      Effect.gen(function* () {
        const identity = yield* DesktopAppIdentity.DesktopAppIdentity;
        const error = yield* identity.resolveUserDataPath.pipe(Effect.flip);

        assert.instanceOf(error, DesktopAppIdentity.DesktopUserDataPathResolutionError);
        assert.equal(error.legacyPath, legacyPath);
        assert.strictEqual(error.cause, cause);
        assert.equal(
          error.message,
          `Failed to inspect legacy desktop user-data path at "${legacyPath}".`,
        );
      }),
      { adoptsLegacyUserDataDir: true, legacyPathProbeError: cause },
    );
  });

  it.effect("configures app identity from the environment commit override", () => {
    const calls: ElectronAppCalls = {
      setAboutPanelOptions: [],
      setDockIcon: [],
      setName: [],
    };

    return withIdentity(
      Effect.gen(function* () {
        const identity = yield* DesktopAppIdentity.DesktopAppIdentity;
        yield* identity.configure;

        assert.deepEqual(calls.setName, ["T3 Code (Alpha)"]);
        assert.equal(calls.setAboutPanelOptions[0]?.applicationName, "T3 Code (Alpha)");
        assert.equal(calls.setAboutPanelOptions[0]?.applicationVersion, "1.2.3");
        assert.equal(calls.setAboutPanelOptions[0]?.version, "0123456789ab");
        // Packaged: the bundle's own icon stands, so a custom one the user
        // attached survives.
        assert.deepEqual(calls.setDockIcon, []);
      }),
      {
        calls,
        environment: {
          env: {
            T3CODE_COMMIT_HASH: "0123456789abcdef",
          },
        },
        pngIconPath: Option.some("/icon.png"),
      },
    );
  });

  it.effect("sets the dock icon only when running unpackaged", () => {
    const calls: ElectronAppCalls = {
      setAboutPanelOptions: [],
      setDockIcon: [],
      setName: [],
    };

    return withIdentity(
      Effect.gen(function* () {
        const identity = yield* DesktopAppIdentity.DesktopAppIdentity;
        yield* identity.configure;

        // Electron shows a generic icon for an unpackaged run, which is the
        // reason this call exists at all.
        assert.deepEqual(calls.setDockIcon, ["/icon.png"]);
      }),
      {
        calls,
        environment: { isPackaged: false },
        pngIconPath: Option.some("/icon.png"),
      },
    );
  });
});
