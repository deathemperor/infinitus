import type { ScheduledTaskWebhookEndpoint } from "@infinitus/contracts";
import { isLocalLoopbackHost } from "@infinitus/shared/hostClassification";
import { CONNECT_NAME } from "@infinitus/shared/productName";

export interface WebhookAddress {
  readonly address: string;
  readonly copyable: boolean;
  readonly note: string | null;
}

export function webhookAddress(
  endpoint: ScheduledTaskWebhookEndpoint,
  httpBaseUrl: string | null,
): WebhookAddress {
  if (endpoint.url !== null) {
    return { address: endpoint.url, copyable: true, note: null };
  }
  if (httpBaseUrl === null) {
    return {
      address: endpoint.path,
      copyable: false,
      note: `Link this environment to ${CONNECT_NAME} for a public URL.`,
    };
  }
  const url = new URL(endpoint.path, httpBaseUrl);
  return {
    address: url.href,
    copyable: true,
    note: isLocalLoopbackHost(url.hostname)
      ? `Only this computer can call this address. Link ${CONNECT_NAME} for a public URL.`
      : `Works wherever this environment's address is reachable, for example over Tailscale or your own proxy. Link ${CONNECT_NAME} for a public URL.`,
  };
}
