import * as Layer from "effect/Layer";

import { CaptureStore } from "../../captures/CaptureStore.ts";
import { InfinitusService } from "../Services/Infinitus.ts";
import { InfinitusCompanion } from "../Services/InfinitusCompanion.ts";
import { InfinitusLimitStops } from "../Services/InfinitusLimitStops.ts";
import { InfinitusPairing } from "../Services/InfinitusPairing.ts";
import { InfinitusSecret } from "../Services/InfinitusSecret.ts";
import { InfinitusSessionHolds } from "../Services/InfinitusSessionHolds.ts";

/** The services `layerInfinitusWsRpc` reads, for a test that builds `Ws.layer` and calls none of them. */
export const layerInfinitusWsRpcUnused = Layer.mergeAll(
  Layer.mock(CaptureStore)({}),
  Layer.mock(InfinitusService)({}),
  Layer.mock(InfinitusCompanion)({}),
  Layer.mock(InfinitusLimitStops)({}),
  Layer.mock(InfinitusPairing)({}),
  Layer.mock(InfinitusSecret)({}),
  Layer.mock(InfinitusSessionHolds)({}),
);
