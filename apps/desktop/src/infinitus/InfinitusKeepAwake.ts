/**
 * Keep the computer awake while a thread's turn runs (#1075). The renderer
 * decides — it already holds every thread's session state — and tells the
 * shell over `setKeepAwake`; this side only holds one
 * `powerSaveBlocker('prevent-app-suspension')` while asked to, idempotent
 * both ways, released when the layer's scope closes with the app. Sleep is
 * never held for a remote environment: those turns run on another machine.
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
>()("@t3tools/desktop/infinitus/InfinitusKeepAwake/InfinitusKeepAwakeService") {}

export interface PowerSaveBlocker {
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
    set: (active) =>
      Effect.gen(function* () {
        if (keepAwake.set(active)) {
          yield* logInfo(active ? "infinitus.keepAwake.held" : "infinitus.keepAwake.released");
        }
      }),
  });
});

export const layer = Layer.effect(InfinitusKeepAwakeService, make);
