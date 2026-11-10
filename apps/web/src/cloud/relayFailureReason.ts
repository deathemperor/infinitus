import { ManagedRelay, relayRequestFailureDetail } from "@infinitus/client-runtime/relay";
import * as Schema from "effect/Schema";
import { CONNECT_NAME } from "@infinitus/shared/productName";

const isRequestFailed = Schema.is(ManagedRelay.ManagedRelayRequestFailedError);
const isRequestTimeout = Schema.is(ManagedRelay.ManagedRelayRequestTimeoutError);

/** One short line for an error toast saying why a T3 Connect request failed. */
export function relayFailureReason(cause: unknown): string | null {
  for (let current = cause, depth = 0; current instanceof Error && depth < 4; depth += 1) {
    if (isRequestTimeout(current)) return `${CONNECT_NAME} timed out. Try again.`;
    if (isRequestFailed(current)) {
      if (current.transportFailed) return `Could not reach ${CONNECT_NAME}. Check your network.`;
      if (current.relayError) {
        return current.relayError._tag === "RelayInternalError"
          ? `${CONNECT_NAME} is unavailable. Try again.`
          : relayRequestFailureDetail(current);
      }
      if (current.status === 504) return `${CONNECT_NAME} timed out. Try again.`;
      if ((current.status ?? 0) >= 500) return `${CONNECT_NAME} is unavailable. Try again.`;
      return relayRequestFailureDetail(current);
    }
    current = current.cause;
  }
  return null;
}
