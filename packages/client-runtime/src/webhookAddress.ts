import type { ScheduledTaskWebhookEndpoint } from "@infinitus/contracts";
import { isLocalLoopbackHost } from "@infinitus/shared/hostClassification";
<<<<<<< HEAD
import { CONNECT_NAME } from "@infinitus/shared/productName";
=======
import { mFallback, msg } from "gt-i18n";
import type { MFunctionType } from "gt-i18n/types";
>>>>>>> upstream-sync-e8c4824b70-upstream-renamed

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
<<<<<<< HEAD
      note: `Link this environment to ${CONNECT_NAME} for a public URL.`,
=======
      note: resolve(msg("Link this environment to T3 Connect for a public URL.")),
>>>>>>> upstream-sync-e8c4824b70-upstream-renamed
    };
  }
  const url = new URL(endpoint.path, httpBaseUrl);
  return {
    address: url.href,
    copyable: true,
    note: isLocalLoopbackHost(url.hostname)
<<<<<<< HEAD
      ? `Only this computer can call this address. Link ${CONNECT_NAME} for a public URL.`
      : `Works wherever this environment's address is reachable, for example over Tailscale or your own proxy. Link ${CONNECT_NAME} for a public URL.`,
=======
      ? resolve(msg("Only this computer can call this address. Link T3 Connect for a public URL."))
      : resolve(
          msg(
            "Works wherever this environment's address is reachable, for example over Tailscale or your own proxy. Link T3 Connect for a public URL.",
          ),
        ),
>>>>>>> upstream-sync-e8c4824b70-upstream-renamed
  };
}
