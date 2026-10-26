/**
 * What the add-connection screen takes from its deep link (#724). Upstream honours
 * `pairingUrl` / `autoConnect` in development builds only, since a production link must
 * not carry attacker-chosen host and token. Infinitus pairs by QR, so a scanned link
 * fills host and code; the user still taps Add. Auto-connect stays development-only.
 */

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
  const pairingUrl = prefillAllowed ? (input.params?.pairingUrl?.trim() ?? "") : "";
  const flag = input.params?.autoConnect;
  return {
    pairingUrl,
    autoConnect: input.dev && pairingUrl.length > 0 && (flag === "1" || flag === "true"),
  };
}
