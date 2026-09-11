import type {
  InfinitusCommandFailed,
  InfinitusProtocolError,
  InfinitusSecretInput,
  InfinitusSecretRefused,
  InfinitusSecretResult,
  InfinitusUnavailable,
} from "@t3tools/contracts/infinitus";
import * as Context from "effect/Context";
import type * as Effect from "effect/Effect";

export interface InfinitusSecretForwardInput extends InfinitusSecretInput {
  /** The auth session asking; the attempt counter is per session. */
  readonly sessionId: string;
}

export interface InfinitusSecretShape {
  /** Sends `secret` to `command` over the control socket (#747), or refuses
      before touching it. The value is unwrapped only into the request line. */
  readonly forward: (
    input: InfinitusSecretForwardInput,
  ) => Effect.Effect<
    InfinitusSecretResult,
    InfinitusSecretRefused | InfinitusUnavailable | InfinitusProtocolError | InfinitusCommandFailed
  >;
}

export class InfinitusSecret extends Context.Service<InfinitusSecret, InfinitusSecretShape>()(
  "t3/infinitus/Services/InfinitusSecret",
) {}
