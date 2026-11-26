/**
 * Pairing requests on Settings › Devices (#710): every phone asking this server in, with the match
 * code to compare against the phone's screen, its time left, and Approve / Deny. Only the desktop
 * app's administrative session may read the stream and decide; any other client is told so (#730).
 *
 * @module InfinitusPairingRequestsCard
 */
import { squashAtomCommandFailure } from "@infinitus/client-runtime/state/runtime";
import { useState } from "react";

import { useNowSecond } from "~/hooks/useNowSecond";
import { usePrimaryEnvironment } from "~/state/environments";
import { infinitusEnvironment } from "~/state/infinitus";
import { useAtomCommand } from "~/state/use-atom-command";

import { Button } from "../../ui/button";
import { ITEM_ROW_CLASSNAME, ITEM_ROW_INNER_CLASSNAME } from "../itemRows";
import { SettingsSection } from "../settingsLayout";
import { FORBIDDEN_NOTICE } from "./pairingAccess.logic";
import { decisionNotice, formatCountdown, pairingRequestRows } from "./pairingRequests.logic";
import { usePairingRequests } from "./usePairingRequests";

const EMPTY_NOTICE =
  "No phone is asking to pair. In the Infinitus app, add a connection, find this Mac on the network and choose “Ask to approve”, or scan a pairing link created under Settings › Connections.";

export function InfinitusPairingRequestsCard() {
  const environmentId = usePrimaryEnvironment()?.environmentId ?? null;
  const access = usePairingRequests(environmentId);
  const requests = access.kind === "ok" ? access.requests : [];
  const decide = useAtomCommand(infinitusEnvironment.pairingDecide, { reportFailure: false });
  const [deciding, setDeciding] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const nowMs = useNowSecond();
  const rows = pairingRequestRows(requests, nowMs);

  const settle = async (id: string, approve: boolean) => {
    if (environmentId === null) return;
    setDeciding(id);
    setNotice(null);
    const result = await decide({ environmentId, input: { id, approve } });
    setDeciding(null);
    const outcome =
      result._tag === "Success"
        ? ({ kind: "decided", decided: result.value.decided } as const)
        : ({
            kind: "failed",
            message: failureMessage(squashAtomCommandFailure(result)),
          } as const);
    setNotice(decisionNotice({ approve, outcome }));
  };

  return (
    <SettingsSection id="infinitus-pairing-requests" title="Pairing requests">
      {access.kind === "forbidden" ? (
        <p role="status" className={`${ITEM_ROW_CLASSNAME} text-sm text-muted-foreground`}>
          {FORBIDDEN_NOTICE}
        </p>
      ) : access.kind === "failed" ? (
        <p role="alert" className={`${ITEM_ROW_CLASSNAME} text-sm text-muted-foreground`}>
          Could not read the pairing requests: {access.message}
        </p>
      ) : rows.length === 0 ? (
        <p role="status" className={`${ITEM_ROW_CLASSNAME} text-sm text-muted-foreground`}>
          {EMPTY_NOTICE}
        </p>
      ) : (
        rows.map((row) => (
          <div key={row.id} className={ITEM_ROW_CLASSNAME}>
            <div className={ITEM_ROW_INNER_CLASSNAME}>
              <div className="flex min-w-0 flex-1 flex-col text-sm">
                <span className="truncate font-medium text-foreground">{row.deviceName}</span>
                {row.detail === null ? null : (
                  <span className="truncate text-xs text-muted-foreground">{row.detail}</span>
                )}
                <span className="text-xs text-muted-foreground">
                  Expires in{" "}
                  <span className="tabular-nums text-foreground">
                    {formatCountdown(row.secondsLeft)}
                  </span>
                </span>
              </div>
              <span
                className="font-mono text-2xl tracking-widest text-foreground"
                aria-label={`Match code ${row.matchCode}`}
              >
                {row.matchCode}
              </span>
              <div className="flex shrink-0 gap-2">
                <Button
                  size="sm"
                  disabled={deciding !== null}
                  onClick={() => void settle(row.id, true)}
                >
                  Approve
                </Button>
                <Button
                  variant="outline"
                  size="sm"
                  disabled={deciding !== null}
                  onClick={() => void settle(row.id, false)}
                >
                  Deny
                </Button>
              </div>
            </div>
          </div>
        ))
      )}
      {notice === null ? null : (
        <p role="alert" className={`${ITEM_ROW_CLASSNAME} text-sm text-muted-foreground`}>
          {notice}
        </p>
      )}
    </SettingsSection>
  );
}

/** The error's own words when it has any (the server's authorization and
    issue errors both carry a `message`), else a line that names nothing. */
function failureMessage(error: unknown): string {
  if (error !== null && typeof error === "object" && "message" in error) {
    const message = (error as { message: unknown }).message;
    if (typeof message === "string" && message !== "") return message;
  }
  return "the server did not take the decision.";
}
