import * as Effect from "effect/Effect";
import * as Logger from "effect/Logger";
import * as References from "effect/References";
import * as Layer from "effect/Layer";

import { ServerConfig } from "./config.ts";
import { makeServerLogFileLogger } from "./infinitus/serverLogFile.ts";

export const ServerLoggerLive = Effect.gen(function* () {
  const config = yield* ServerConfig;
  const minimumLogLevelLayer = Layer.succeed(References.MinimumLogLevel, config.logLevel);
  const loggerLayer = Logger.layer(
    [
      Logger.consolePretty(),
      Logger.tracerLogger,
      // Fork (#1182): stdout is only kept by whoever started the server, and a
      // packaged desktop backend has no one keeping it. `Logger.layer` takes
      // the effect and owns its scope, so the batch flushes on shutdown.
      makeServerLogFileLogger({ filePath: config.serverLogNdjsonPath }),
    ],
    { mergeWithExisting: false },
  );

  return Layer.mergeAll(loggerLayer, minimumLogLevelLayer);
}).pipe(Layer.unwrap);
