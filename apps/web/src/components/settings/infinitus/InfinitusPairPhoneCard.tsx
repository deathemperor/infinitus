/**
 * "Pair a phone" on Settings › Infinitus › Devices: a QR of a one-time pairing
 * link whose host is the Mac's Cloudflare quick tunnel while it is up, else
 * the server's own address on the Mac's Wi‑Fi (the desktop's advertised
 * address, or what the server reports in `lanHttpBaseUrls`, #651), so a phone
 * off the network or beside the Mac can reach this server. The token is
 * minted by upstream's pairing-token endpoint with the standard scopes and
 * TTL; nothing here adds an auth surface. The link carries the phone marker,
 * so a Camera-app scan that lands in Safari is told to use the app instead
 * of spending the code (#724).
 *
 * @module InfinitusPairPhoneCard
 */
import { useCallback, useEffect, useState } from "react";

import { createServerPairingCredential, revokeServerPairingLink } from "~/environments/primary";
import { isLoopbackHostname } from "~/environments/primary/target";
import { writeTextToClipboard } from "~/hooks/useCopyToClipboard";
import { desktopNetworkAccessStateAtom } from "~/state/desktopNetworkAccess";
import { useEnvironmentQuery } from "~/state/query";

import { Button } from "../../ui/button";
import { QRCodeSvg } from "../../ui/qr-code";
import { SettingsSection, useRelativeTimeTick } from "../settingsLayout";
import { useInfinitusEnvironment } from "./InfinitusPrefsPanel";
import {
  formatCountdown,
  lanPairingOrigin,
  pairPhoneCardModel,
  type PairPhoneReach,
  type PhonePairingLink,
  SCAN_IN_APP_NOTICE,
} from "./pairPhone.logic";

const PAIRING_LABEL = "Infinitus phone";

function pageOrigin(): string | null {
  if (typeof window === "undefined" || window.location === undefined) return null;
  return isLoopbackHostname(window.location.hostname) ? null : window.location.origin;
}

export function InfinitusPairPhoneCard() {
  const { snapshot, serverLanOrigins } = useInfinitusEnvironment();
  const [link, setLink] = useState<PhonePairingLink | null>(null);
  const [minting, setMinting] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [copied, setCopied] = useState(false);
  const [reach, setReach] = useState<PairPhoneReach>("tunnel");
  const [codeShown, setCodeShown] = useState(false);
  // The countdown ticks only while there is one to draw.
  const nowMs = useRelativeTimeTick(link === null ? 60_000 : 1_000);
  // The desktop app knows the server's LAN address (Settings › Connections ›
  // Network access); a browser has only its own origin to go on.
  const desktopNetworkAccess = useEnvironmentQuery(
    typeof window !== "undefined" && window.desktopBridge ? desktopNetworkAccessStateAtom : null,
  );

  const model = pairPhoneCardModel({
    forkTunnel: snapshot?.status?.forkTunnel,
    lanOrigin: lanPairingOrigin({
      serverExposure: desktopNetworkAccess.data?.serverExposureState ?? null,
      serverLanOrigins,
      pageOrigin: pageOrigin(),
    }),
    reach,
    link,
    nowMs,
  });

  const mint = useCallback(async () => {
    setMinting(true);
    setError(null);
    setCopied(false);
    setCodeShown(false);
    const previous = link;
    try {
      const created = await createServerPairingCredential({ label: PAIRING_LABEL });
      setLink({
        id: created.id,
        credential: created.credential,
        expiresAtMs: created.expiresAt.epochMilliseconds,
      });
      // The link this one replaces is single-use and short-lived either way;
      // revoking it just keeps the Connections page's list honest.
      if (previous !== null) await revokeServerPairingLink(previous.id).catch(() => undefined);
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : "Could not create a pairing link.");
    } finally {
      setMinting(false);
    }
  }, [link]);

  const copy = useCallback(async () => {
    if (model.link.kind !== "active") return;
    try {
      await writeTextToClipboard(model.link.url, "pairing link");
      setCopied(true);
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : "Could not copy the pairing link.");
    }
  }, [model.link]);

  useEffect(() => {
    if (!copied) return;
    const id = setTimeout(() => setCopied(false), 2_000);
    return () => clearTimeout(id);
  }, [copied]);

  return (
    <SettingsSection id="infinitus-pair-phone" title="Pair a phone">
      <div className="flex flex-col gap-3 px-3 py-3 text-[13px] sm:px-4">
        {model.tunnelNotice === null ? null : (
          <p role="status" className="text-muted-foreground">
            {model.tunnelNotice}
          </p>
        )}
        {model.lanNotice === null ? null : (
          <p className="text-muted-foreground">{model.lanNotice}</p>
        )}
        {model.reachChoice ? (
          <div className="flex flex-wrap items-center gap-2" role="radiogroup" aria-label="Reach">
            <span className="text-muted-foreground">Pair over</span>
            {(["tunnel", "lan"] as const).map((option) => (
              <Button
                key={option}
                role="radio"
                aria-checked={reach === option}
                variant={reach === option ? "secondary" : "outline"}
                size="sm"
                onClick={() => setReach(option)}
              >
                {option === "tunnel" ? "Internet" : "Same Wi‑Fi"}
              </Button>
            ))}
          </div>
        ) : null}
        {model.origin === null ? null : (
          <>
            {model.link.kind === "active" ? (
              <div className="flex flex-col items-start gap-3 sm:flex-row sm:items-center">
                <div className="rounded-xl border border-border/60 bg-white p-3">
                  <QRCodeSvg
                    value={model.link.url}
                    size={148}
                    level="M"
                    marginSize={1}
                    title="Pairing link — scan with the Infinitus phone app, or its Camera app"
                  />
                </div>
                <div className="flex flex-col gap-2">
                  <p className="text-muted-foreground">{SCAN_IN_APP_NOTICE}</p>
                  <p className="text-muted-foreground">
                    Expires in{" "}
                    <span className="tabular-nums text-foreground">
                      {formatCountdown(model.link.secondsLeft)}
                    </span>
                    .
                  </p>
                  <div className="flex flex-wrap gap-2">
                    <Button variant="outline" size="sm" onClick={() => void copy()}>
                      {copied ? "Copied" : "Copy link"}
                    </Button>
                    <Button
                      variant="outline"
                      size="sm"
                      disabled={minting}
                      onClick={() => void mint()}
                    >
                      New link
                    </Button>
                    <Button variant="ghost" size="sm" onClick={() => setCodeShown((v) => !v)}>
                      {codeShown ? "Hide code" : "Type it instead"}
                    </Button>
                  </div>
                  {codeShown && link !== null ? (
                    <p className="text-muted-foreground">
                      In the app, add a connection by hand: host{" "}
                      <span className="font-mono text-foreground">{model.link.host}</span>, code{" "}
                      <span className="font-mono text-foreground">{link.credential}</span>.
                    </p>
                  ) : null}
                </div>
              </div>
            ) : (
              <div className="flex flex-wrap items-center gap-3">
                {model.link.kind === "expired" ? (
                  <p className="text-muted-foreground">That link expired.</p>
                ) : null}
                <Button variant="outline" size="sm" disabled={minting} onClick={() => void mint()}>
                  {minting ? "Creating…" : model.link.kind === "expired" ? "New link" : "Show QR"}
                </Button>
              </div>
            )}
          </>
        )}
        {error === null ? null : (
          <p role="alert" className="text-destructive">
            {error}
          </p>
        )}
      </div>
    </SettingsSection>
  );
}
