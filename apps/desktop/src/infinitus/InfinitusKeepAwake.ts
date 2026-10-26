/**
 * Keep the computer awake while a thread's turn runs (#1075). The renderer decides and
 * calls `setKeepAwake`; this side holds one idempotent `powerSaveBlocker`, released when
 * the scope closes. Sleep is never held for a remote environment.
 */
import * as Electron from "electron";
import * as Context from "effect/Context";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";

import { makeComponentLogger } from "../app/DesktopObservability.ts";

export class InfinitusKeepAwakeService extends Context.Service<
  InfinitusKeepAwakeService,
  {
    readonly set: (active: boolean) => Effect.Effect<void>;
  }
>()("@infinitus/desktop/infinitus/InfinitusKeepAwake/InfinitusKeepAwakeService") {}

interface PowerSaveBlocker {
  readonly start: (type: "prevent-app-suspension") => number;
  readonly stop: (id: number) => void;
}

/** One blocker id while held; asking twice in a row changes nothing. */
export function makeKeepAwake(blocker: PowerSaveBlocker) {
  let id: number | null = null;
  return {
    get held() {
      return id !== null;
    },
    set: (active: boolean): boolean => {
      if (active === (id !== null)) return false;
      if (active) {
        id = blocker.start("prevent-app-suspension");
      } else if (id !== null) {
        blocker.stop(id);
        id = null;
      }
      return true;
    },
  };
}

const { logInfo } = makeComponentLogger("infinitus-keep-awake");

const make = Effect.gen(function* () {
  const keepAwake = makeKeepAwake(Electron.powerSaveBlocker);
  yield* Effect.addFinalizer(() => Effect.sync(() => keepAwake.set(false)));
  return InfinitusKeepAwakeService.of({
    set: Effect.fn("infinitus.keepAwake.set")(function* (active) {
      if (keepAwake.set(active)) {
        yield* logInfo(active ? "infinitus.keepAwake.held" : "infinitus.keepAwake.released");
      }
    }),
  });
});

export const layer = Layer.effect(InfinitusKeepAwakeService, make);
