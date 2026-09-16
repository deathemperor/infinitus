import {
  ORCHESTRATION_PROTOCOL_QUERY_PARAM,
  ORCHESTRATION_PROTOCOL_VERSION,
  type ExecutionEnvironmentDescriptor,
} from "@infinitus/contracts";

import { ConnectionBlockedError } from "./model.ts";
import { PRODUCT_NAME } from "@infinitus/shared/productName";

export function orchestrationProtocolCompatibilityError(
  descriptor: ExecutionEnvironmentDescriptor,
): ConnectionBlockedError | null {
  // Servers shipped before negotiation use the original wire protocol.
  const serverProtocolVersion = descriptor.orchestrationProtocolVersion ?? 1;
  if (serverProtocolVersion === ORCHESTRATION_PROTOCOL_VERSION) {
    return null;
  }
  return new ConnectionBlockedError({
    reason: "unsupported",
    detail:
      serverProtocolVersion > ORCHESTRATION_PROTOCOL_VERSION
        ? `This client is not supported by this server. Update your app or use a compatible release to connect to ${descriptor.label}.`
        : `This client requires a newer server. Update ${PRODUCT_NAME} on ${descriptor.label} to connect.`,
  });
}

export function appendOrchestrationProtocol(socketUrl: string): string {
  const url = new URL(socketUrl);
  url.searchParams.set(ORCHESTRATION_PROTOCOL_QUERY_PARAM, String(ORCHESTRATION_PROTOCOL_VERSION));
  return url.toString();
}
