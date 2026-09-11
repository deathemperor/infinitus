import * as NodeOS from "node:os";

import { HostProcessEnvironment, HostProcessPlatform } from "@t3tools/shared/hostProcess";
import { resolveInfinitusControlSocketPath } from "@t3tools/shared/infinitusControl";
import {
  INFINITUS_CONTROL_DEFAULT_MAX_REPLY_BYTES,
  INFINITUS_CONTROL_DEFAULT_TIMEOUT_MS,
  requestInfinitusControl,
} from "@t3tools/shared/infinitusControlSocket";
import { InfinitusUnavailable } from "@t3tools/contracts/infinitus";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";

import {
  InfinitusControlClient,
  InfinitusControlClientConfig,
  type InfinitusControlClientShape,
  type InfinitusControlRequestInput,
} from "../Services/InfinitusControlClient.ts";

const makeInfinitusControlClient = Effect.gen(function* () {
  const config = yield* InfinitusControlClientConfig;

  // The wire protocol itself lives in `@t3tools/shared/infinitusControlSocket`
  // (the desktop shell speaks it too); this layer only adds the resolved path
  // and the configured limits.
  const request: InfinitusControlClientShape["request"] = Effect.fn(
    "InfinitusControlClient.request",
  )(function* (input: InfinitusControlRequestInput) {
    // The verb only (#676): args and options stay on the service span above.
    yield* Effect.annotateCurrentSpan({ "infinitus.command": input.command });
    const socketPath = config.socketPath;
    if (socketPath === null) {
      return yield* new InfinitusUnavailable({ path: "", cause: "unsupported platform" });
    }
    return yield* requestInfinitusControl({
      socketPath,
      request: input,
      timeoutMs: config.timeoutMs,
      maxReplyBytes: config.maxReplyBytes,
    });
  });

  return {
    socketPath: config.socketPath,
    request,
  } satisfies InfinitusControlClientShape;
});

export const InfinitusControlClientLive = Layer.effect(
  InfinitusControlClient,
  makeInfinitusControlClient,
);

export const InfinitusControlClientConfigLive = Layer.effect(
  InfinitusControlClientConfig,
  Effect.gen(function* () {
    const platform = yield* HostProcessPlatform;
    const env = yield* HostProcessEnvironment;
    return {
      socketPath: resolveInfinitusControlSocketPath({
        platform,
        env,
        homeDir: NodeOS.homedir(),
      }),
      timeoutMs: INFINITUS_CONTROL_DEFAULT_TIMEOUT_MS,
      maxReplyBytes: INFINITUS_CONTROL_DEFAULT_MAX_REPLY_BYTES,
    };
  }),
);
