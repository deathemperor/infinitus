import { InfinitusWsRpcGroup, WS_METHODS } from "@infinitus/contracts";
import * as Effect from "effect/Effect";
import * as Stream from "effect/Stream";

import type * as EnvironmentAuth from "../../auth/EnvironmentAuth.ts";
import { CaptureStore } from "../../captures/CaptureStore.ts";
import { RpcInstrumentation } from "../../observability/RpcInstrumentation.ts";
import * as UsageService from "../../usage/UsageService.ts";
import { InfinitusService } from "../Services/Infinitus.ts";
import { InfinitusCompanion } from "../Services/InfinitusCompanion.ts";
import { InfinitusLimitStops } from "../Services/InfinitusLimitStops.ts";
import { InfinitusPairing } from "../Services/InfinitusPairing.ts";
import { InfinitusSecret } from "../Services/InfinitusSecret.ts";
import { InfinitusSessionHolds } from "../Services/InfinitusSessionHolds.ts";

// As in ws.ts: middleware added later wraps middleware added earlier, so
// instrumentation wraps authorization.
const InfinitusServerWsRpcGroup = InfinitusWsRpcGroup.middleware(RpcInstrumentation);

/**
 * The fork's WebSocket RPC handlers, merged beside upstream's `layerWsRpc` in
 * `ws.ts`. They stay out of upstream's handler object so that object keeps
 * upstream's size: one `toLayer` over every RPC exceeds TypeScript's
 * instantiation limit, and the `any` it then infers reaches `runServer`.
 */
export const layerInfinitusWsRpc = (currentSession: EnvironmentAuth.AuthenticatedSession) =>
  InfinitusServerWsRpcGroup.toLayer(
    Effect.gen(function* () {
      const usage = yield* UsageService.UsageService;
      const infinitus = yield* InfinitusService;
      const infinitusCompanion = yield* InfinitusCompanion;
      const infinitusSecret = yield* InfinitusSecret;
      const infinitusPairing = yield* InfinitusPairing;
      const infinitusLimitStops = yield* InfinitusLimitStops;
      // #616, #743: the holds stream and "Run now".
      const infinitusSessionHolds = yield* InfinitusSessionHolds;
      const captureStore = yield* CaptureStore;
      return InfinitusServerWsRpcGroup.of({
        // #659: the stats panel.
        [WS_METHODS.serverGetStats]: (input) => usage.readStats(input),
        // The stream itself is what makes the server poll the control socket,
        // so this must stay the only way a client reads Infinitus.
        [WS_METHODS.subscribeInfinitus]: (input) => infinitus.changes(input),
        [WS_METHODS.infinitusCommand]: (input) =>
          infinitus
            .command(input)
            // `result` is an optional key: a command that answers with no
            // payload sends no key rather than an explicit undefined.
            .pipe(Effect.map((result) => (result === undefined ? {} : { result }))),
        [WS_METHODS.infinitusLaunch]: (_input) => infinitusCompanion.launch,
        [WS_METHODS.infinitusSecret]: (input) =>
          infinitusSecret.forward({
            ...input,
            sessionId: currentSession.sessionId,
            scopes: currentSession.scopes,
          }),
        [WS_METHODS.subscribeInfinitusPairing]: (_input) => infinitusPairing.pending,
        // The threads a Claude usage limit stopped (#648, #1627): the sidebar's
        // "Limited" pill for a parked turn. Thread ids, accounts and resets only.
        [WS_METHODS.subscribeInfinitusLimitStops]: (_input) => infinitusLimitStops.stopped,
        [WS_METHODS.infinitusPairingDecide]: (input) =>
          infinitusPairing.decide({ ...input, approverScopes: currentSession.scopes }),
        // Session priority mode (#616, #741, #743): the threads held for
        // headroom and paused for it, one whole list; "Run now" / "Resume now".
        [WS_METHODS.subscribeInfinitusHolds]: (_input) => infinitusSessionHolds.held,
        [WS_METHODS.infinitusReleaseThread]: (input) =>
          infinitusSessionHolds.release(input.threadId),
        // Captures (#433): one list per project.
        [WS_METHODS.subscribeCaptures]: (input) =>
          Stream.unwrap(captureStore.subscribe(input.projectId)),
        [WS_METHODS.capturesApply]: (input) =>
          captureStore.apply(input.projectId, input.command).pipe(Effect.as({})),
      });
    }),
  );
