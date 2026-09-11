import type { PairingApprovalRequest } from "@t3tools/contracts/infinitusPairing";
import * as Cause from "effect/Cause";
import type { AsyncResult } from "effect/unstable/reactivity";

/**
 * What the pairing-requests stream tells this client (#730). Only an
 * administrative session — the desktop app on the Mac itself — holds the
 * `access:read` / `access:write` scopes the stream and the decision need; a
 * client paired through a QR or `t3 pair` link does not, and its stream fails
 * at once with `EnvironmentAuthorizationError`. That client must be told who
 * can approve, not shown the empty state as if nothing were pending.
 */
export type PairingAccess =
  | { readonly kind: "loading" }
  | { readonly kind: "ok"; readonly requests: ReadonlyArray<PairingApprovalRequest> }
  | { readonly kind: "forbidden" }
  | { readonly kind: "failed"; readonly message: string };

export const FORBIDDEN_NOTICE = "Only the desktop app on this Mac can approve devices.";

/** The server refusing the stream for want of a scope, as opposed to any
    other way it can fail. */
export function isAuthorizationFailure(error: unknown): boolean {
  return (
    error !== null &&
    typeof error === "object" &&
    (error as { _tag?: unknown })._tag === "EnvironmentAuthorizationError"
  );
}

export function pairingAccessOf(
  result: AsyncResult.AsyncResult<ReadonlyArray<PairingApprovalRequest>, unknown>,
): PairingAccess {
  switch (result._tag) {
    case "Initial":
      return { kind: "loading" };
    case "Success":
      return { kind: "ok", requests: result.value };
    case "Failure": {
      const error = Cause.squash(result.cause);
      if (isAuthorizationFailure(error)) return { kind: "forbidden" };
      const message =
        error instanceof Error && error.message.trim() !== ""
          ? error.message
          : "the pairing requests could not be read.";
      return { kind: "failed", message };
    }
  }
}
