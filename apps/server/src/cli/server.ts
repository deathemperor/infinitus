import { PRODUCT_NAME } from "@infinitus/shared/productName";
import * as HostProcess from "@infinitus/shared/HostProcess";
import * as Effect from "effect/Effect";
import * as FileSystem from "effect/FileSystem";
import * as Option from "effect/Option";
import * as Schema from "effect/Schema";
import { Command, GlobalFlag } from "effect/cli";
import * as CliError from "effect/cli/CliError";

import * as ServerConfig from "../config.ts";
import { awaitLauncherLoss } from "../launcherWatch.ts";
import { runServer } from "../server.ts";
import { type CliServerFlags, resolveServerConfig, sharedServerCommandFlags } from "./config.ts";

const encodeCommand = Schema.encodeEffect(Schema.fromJsonString(Schema.String));

// The desktop launcher reads this process's stdout and stderr. Once it is gone,
// every log write fails, and Node turns an unhandled stream error into a crash
// that skips shutdown and leaves the ownership lock and runtime record behind.
function ignoreClosedLauncherPipe(error: NodeJS.ErrnoException): void {
  if (error.code !== "EPIPE" && error.code !== "ERR_STREAM_DESTROYED") throw error;
}

const runServerCommand = Effect.fn("server.runServerCommand")(function* (
  flags: CliServerFlags,
  options?: {
    readonly startupPresentation?: ServerConfig.StartupPresentation;
    readonly forceAutoBootstrapProjectFromCwd?: boolean;
    readonly rejectRunningServer?: boolean;
  },
) {
  const logLevel = yield* GlobalFlag.LogLevel;
  const config = yield* resolveServerConfig(flags, logLevel, options);
  const run = runServer.pipe(Effect.provideService(ServerConfig.ServerConfig, config));
  if (config.mode !== "desktop" || config.desktopBootstrapToken === undefined) return yield* run;
  yield* Effect.sync(() => {
    process.stdout.on("error", ignoreClosedLauncherPipe);
    process.stderr.on("error", ignoreClosedLauncherPipe);
  });
  return yield* Effect.raceFirst(
    run,
    awaitLauncherLoss().pipe(
      // End like SIGTERM does (interrupt-only exit, so the runtime forces process exit).
      Effect.andThen(Effect.interrupt),
    ),
  );
});

export const runDefaultServerCommand = Effect.fn("server.runDefaultServerCommand")(function* (
  flags: CliServerFlags,
) {
  if (Option.isSome(flags.cwd)) {
    const cwd = flags.cwd.value.trim();
    const fs = yield* FileSystem.FileSystem;
    const platform = yield* HostProcess.Platform;
    const explicitPath =
      cwd === "." ||
      cwd === ".." ||
      cwd === "~" ||
      /[/\\]/.test(cwd) ||
      (platform === "win32" && /^[a-z]:/i.test(cwd));
    if (!explicitPath && (!(yield* fs.exists(cwd)) || (yield* fs.stat(cwd)).type !== "Directory")) {
      return yield* new CliError.UserError({
        cause: cwd,
        userMessage: `Unknown command ${yield* encodeCommand(cwd)}. Use "t3 --help" for commands or an explicit path such as "t3 ./my-project" for a new directory.`,
      });
    }
  }
  return yield* runServerCommand(flags, { rejectRunningServer: true });
});

export const startCommand = Command.make("start", { ...sharedServerCommandFlags }).pipe(
<<<<<<< HEAD
  Command.withDescription(`Run the ${PRODUCT_NAME} server.`),
=======
  Command.withDescription("Same as `t3`."),
  Command.unlisted,
>>>>>>> upstream-sync-2359643cff-upstream-renamed
  Command.withHandler((flags) => runServerCommand(flags, { rejectRunningServer: true })),
);

export const serveCommand = Command.make("serve", { ...sharedServerCommandFlags }).pipe(
  Command.withShortDescription("Run T3 Code in this terminal, with no browser."),
  Command.withDescription(
<<<<<<< HEAD
    `Run the ${PRODUCT_NAME} server without opening a browser and print headless pairing details.`,
=======
    "Run T3 Code in this terminal without opening a browser, and print pairing details. The background service runs this. To set up access from your other devices, run `t3 up`.",
>>>>>>> upstream-sync-2359643cff-upstream-renamed
  ),
  Command.withHandler((flags) =>
    runServerCommand(flags, {
      startupPresentation: "headless",
      forceAutoBootstrapProjectFromCwd: false,
    }),
  ),
);
