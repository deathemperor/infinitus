import type { ScheduledTaskWebhookEndpoint } from "@infinitus/contracts";
import { isLocalLoopbackHost } from "@infinitus/shared/hostClassification";
import { mFallback, msg } from "gt-i18n";
import type { MFunctionType } from "gt-i18n/types";

export interface WebhookAddress {
  readonly address: string;
  readonly copyable: boolean;
  readonly note: string | null;
}

export function webhookAddress(
  endpoint: ScheduledTaskWebhookEndpoint,
  httpBaseUrl: string | null,
  resolve: MFunctionType = mFallback,
): WebhookAddress {
  if (endpoint.url !== null) {
    return { address: endpoint.url, copyable: true, note: null };
  }
  if (httpBaseUrl === null) {
    return {
      address: endpoint.path,
      copyable: false,
      note: resolve(msg("Link this environment to Infinitus Connect for a public URL.")),
    };
  }
  const url = new URL(endpoint.path, httpBaseUrl);
  return {
    address: url.href,
    copyable: true,
    note: isLocalLoopbackHost(url.hostname)
      ? resolve(
          msg("Only this computer can call this address. Link Infinitus Connect for a public URL."),
        )
      : resolve(
          msg(
            "Works wherever this environment's address is reachable, for example over Tailscale or your own proxy. Link Infinitus Connect for a public URL.",
          ),
        ),
  };
}
