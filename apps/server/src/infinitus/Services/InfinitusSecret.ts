import type {
  InfinitusCommandFailed,
  InfinitusProtocolError,
  InfinitusSecretInput,
  InfinitusSecretRefused,
  InfinitusSecretResult,
  InfinitusUnavailable,
} from "@t3tools/contracts/infinitus";
import type { AuthEnvironmentScope } from "@t3tools/contracts";
import * as Context from "effect/Context";
import type * as Effect from "effect/Effect";

export interface InfinitusSecretForwardInput extends InfinitusSecretInput {
  /** The auth session asking; the attempt counter is per session. */
  readonly sessionId: string;
  /** Its scopes: a sign-in verb takes a standard client, the rest `access:write`. */
  readonly scopes: ReadonlyArray<AuthEnvironmentScope>;
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
