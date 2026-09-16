import { EnvironmentHttpApi } from "@t3tools/contracts";
import { TeamControlUnavailable } from "@t3tools/contracts/infinitusTeamControl";
import * as Effect from "effect/Effect";
import * as HttpApiBuilder from "effect/unstable/httpapi/HttpApiBuilder";

import { annotateEnvironmentRequest } from "../../auth/http.ts";
import { InfinitusControlClient } from "../Services/InfinitusControlClient.ts";

/** `{ack}` as the Mac answers `team-inbox`; anything else reads as no ack. */
const ackOf = (result: unknown): string | null => {
  if (typeof result !== "object" || result === null || !("ack" in result)) return null;
  const ack = (result as { readonly ack: unknown }).ack;
  return typeof ack === "string" ? ack : null;
};

/**
 * Team delegated control's network lane (#1313, spec §8): the sealed
 * envelope goes to the Mac's `team-inbox` on the control request line's
 * `secret` field — the same field every stdin value rides — and the sealed
 * ack comes back. The route carries no principal and asks for none; the
 * Mac verifies the envelope. A Mac that is not running or refuses the verb
 * is 503 with no detail, and the driver falls to the store lane.
 */
export const infinitusTeamControlHttpApiLayer = HttpApiBuilder.group(
  EnvironmentHttpApi,
  "infinitusTeamControl",
  Effect.fnUntraced(function* (handlers) {
    const control = yield* InfinitusControlClient;
    return handlers.handle(
      "teamCommand",
      Effect.fn("environment.infinitusTeamControl.command")(function* (args) {
        yield* annotateEnvironmentRequest(args.endpoint.name);
        const result = yield* control
          .request({ command: "team-inbox", secret: args.payload.envelope })
          .pipe(Effect.mapError(() => new TeamControlUnavailable()));
        return { ack: ackOf(result) };
      }),
    );
  }),
);
