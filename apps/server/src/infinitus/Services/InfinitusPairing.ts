import type { AuthEnvironmentScope, EnvironmentAuthorizationError } from "@t3tools/contracts";
import type {
  PairingApprovalCreated,
  PairingApprovalDecideResult,
  PairingApprovalIssueFailed,
  PairingApprovalNotFound,
  PairingApprovalPollResult,
  PairingApprovalRefused,
  PairingApprovalRequest,
} from "@t3tools/contracts/infinitusPairing";
import * as Context from "effect/Context";
import type * as Effect from "effect/Effect";
import type * as Stream from "effect/Stream";

export interface InfinitusPairingShape {
  /** A phone asks to be let in. `remoteAddress` is what the server saw, used
      only for the per-address cap and the desktop's row. */
  readonly create: (input: {
    readonly deviceName: string;
    readonly os?: string;
    readonly remoteAddress?: string;
    readonly secret: string;
  }) => Effect.Effect<PairingApprovalCreated, PairingApprovalRefused>;
  /** The phone asks what became of its request; the secret must match. */
  readonly poll: (input: {
    readonly id: string;
    readonly secret: string;
  }) => Effect.Effect<PairingApprovalPollResult, PairingApprovalNotFound>;
  /** The current pending list, then the whole list again on every change. */
  readonly pending: Stream.Stream<ReadonlyArray<PairingApprovalRequest>>;
  /** The desktop approves or denies. Approving mints the one-time pairing
      credential with the standard client scopes, so the approver's own
      session must hold each of them. */
  readonly decide: (input: {
    readonly id: string;
    readonly approve: boolean;
    readonly approverScopes: ReadonlyArray<AuthEnvironmentScope>;
  }) => Effect.Effect<
    PairingApprovalDecideResult,
    EnvironmentAuthorizationError | PairingApprovalIssueFailed
  >;
}

export class InfinitusPairing extends Context.Service<InfinitusPairing, InfinitusPairingShape>()(
  "t3/infinitus/Services/InfinitusPairing",
) {}
