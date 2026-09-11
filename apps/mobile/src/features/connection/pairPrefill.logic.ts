/**
 * What the add-connection screen takes from its deep link (#724). Upstream
 * honours `pairingUrl` / `autoConnect` in development builds only: a
 * production link must not arrive with attacker-chosen host and token filled
 * in. The Infinitus variant pairs with its own Mac by QR, so a scanned link
 * that reaches the app lands on the sheet with host and code filled — the
 * user still reads both and taps Add. Auto-connect stays development-only:
 * nothing pairs without that tap. A universal link from the Devices card
 * (`https://infinitus.run/pair#…&to=<origin>`, #724) is rewritten to its
 * origin's `/pair` first, so the fields read the Mac, not the site.
 */
import { resolvePairingLink } from "./universalPairLink.logic";

export interface PairingPrefill {
  /** The link to parse into the Host and code fields; "" for none. */
  readonly pairingUrl: string;
  readonly autoConnect: boolean;
}

const INFINITUS_APP_VARIANT = "infinitus";

export function routePairingPrefill(input: {
  readonly params: { readonly pairingUrl?: string; readonly autoConnect?: string } | undefined;
  readonly dev: boolean;
  readonly appVariant: unknown;
}): PairingPrefill {
  const prefillAllowed = input.dev || input.appVariant === INFINITUS_APP_VARIANT;
  const pairingUrl = prefillAllowed
    ? resolvePairingLink(input.params?.pairingUrl?.trim() ?? "")
    : "";
  const flag = input.params?.autoConnect;
  return {
    pairingUrl,
    autoConnect: input.dev && pairingUrl.length > 0 && (flag === "1" || flag === "true"),
  };
}
