import type {
  InfinitusCommandFailed,
  InfinitusProtocolError,
  InfinitusUnavailable,
} from "@t3tools/contracts/infinitus";
import * as Context from "effect/Context";
import type * as Effect from "effect/Effect";

import type { InfinitusControlRequestInput } from "@t3tools/shared/infinitusControlSocket";

export type { InfinitusControlRequestInput };

export interface InfinitusControlClientShape {
  /** Resolved once at layer construction; null means Infinitus cannot run here. */
  readonly socketPath: string | null;
  /**
   * Runs one command over a fresh connection and resolves to the reply's
   * `result`, which is `undefined` for commands that answer with no payload.
   */
  readonly request: (
    input: InfinitusControlRequestInput,
  ) => Effect.Effect<
    unknown,
    InfinitusUnavailable | InfinitusProtocolError | InfinitusCommandFailed
  >;
}

export class InfinitusControlClient extends Context.Service<
  InfinitusControlClient,
  InfinitusControlClientShape
>()("t3/infinitus/Services/InfinitusControlClient") {}

export interface InfinitusControlClientConfigShape {
  readonly socketPath: string | null;
  readonly timeoutMs: number;
  readonly maxReplyBytes: number;
}

export class InfinitusControlClientConfig extends Context.Service<
  InfinitusControlClientConfig,
  InfinitusControlClientConfigShape
>()("t3/infinitus/Services/InfinitusControlClient/InfinitusControlClientConfig") {}
