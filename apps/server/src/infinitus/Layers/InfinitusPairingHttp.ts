import { EnvironmentHttpApi } from "@t3tools/contracts";
import * as Effect from "effect/Effect";
import { HttpServerRequest } from "effect/unstable/http";
import * as HttpApiBuilder from "effect/unstable/httpapi/HttpApiBuilder";

import { annotateEnvironmentRequest } from "../../auth/http.ts";
import { deriveAuthClientMetadata } from "../../auth/utils.ts";
import { InfinitusPairing } from "../Services/InfinitusPairing.ts";

/** The phone's two unauthenticated routes (#710). The request id is the only
    thing about a request that reaches a span; the secret and the match code
    never do. */
export const infinitusPairingHttpApiLayer = HttpApiBuilder.group(
  EnvironmentHttpApi,
  "infinitusPairing",
  Effect.fnUntraced(function* (handlers) {
    const pairing = yield* InfinitusPairing;
    return handlers
      .handle(
        "pairingApprovalCreate",
        Effect.fn("environment.infinitusPairing.create")(function* (args) {
          yield* annotateEnvironmentRequest(args.endpoint.name);
          const request = yield* HttpServerRequest.HttpServerRequest;
          const seen = deriveAuthClientMetadata({ request });
          const os = args.payload.os ?? seen.os;
          return yield* pairing.create({
            deviceName: args.payload.deviceName,
            secret: args.payload.secret,
            ...(os !== undefined ? { os } : {}),
            ...(seen.ipAddress !== undefined ? { remoteAddress: seen.ipAddress } : {}),
          });
        }),
      )
      .handle(
        "pairingApprovalPoll",
        Effect.fn("environment.infinitusPairing.poll")(function* (args) {
          yield* annotateEnvironmentRequest(args.endpoint.name);
          return yield* pairing.poll(args.payload);
        }),
      );
  }),
);
