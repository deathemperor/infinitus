import { ManagedRelay, relayRequestFailureDetail } from "@infinitus/client-runtime/relay";
import * as Schema from "effect/Schema";
<<<<<<< HEAD
import { CONNECT_NAME } from "@infinitus/shared/productName";
=======
import { msg } from "gt-react";

import { m } from "../i18n/messages";
>>>>>>> upstream-sync-9661141276-upstream-renamed

const isRequestFailed = Schema.is(ManagedRelay.ManagedRelayRequestFailedError);
const isRequestTimeout = Schema.is(ManagedRelay.ManagedRelayRequestTimeoutError);

/** One short line for an error toast saying why a T3 Connect request failed. */
export function relayFailureReason(cause: unknown): string | null {
  for (let current = cause, depth = 0; current instanceof Error && depth < 4; depth += 1) {
<<<<<<< HEAD
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
=======
    if (isRequestTimeout(current)) return m(msg("T3 Connect timed out. Try again."));
    if (isRequestFailed(current)) {
      if (current.transportFailed) return m(msg("Could not reach T3 Connect. Check your network."));
      if (current.relayError) {
        return current.relayError._tag === "RelayInternalError"
          ? m(msg("T3 Connect is unavailable. Try again."))
          : relayRequestFailureDetail(current);
      }
      if (current.status === 504) return m(msg("T3 Connect timed out. Try again."));
      if ((current.status ?? 0) >= 500) return m(msg("T3 Connect is unavailable. Try again."));
>>>>>>> upstream-sync-9661141276-upstream-renamed
      return relayRequestFailureDetail(current);
    }
    current = current.cause;
  }
  return null;
}
