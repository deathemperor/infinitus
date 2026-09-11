/**
 * "Pairing requests" on Settings › Infinitus › Devices (#710): every phone
 * currently asking this server to let it in, each with the match code the
 * user compares against the phone's screen, its time left, and Approve /
 * Deny. Approving mints the one-time credential the phone then collects by
 * polling; nothing about it reaches this page — the stream carries the
 * request's metadata and the match code only.
 *
 * @module InfinitusPairingRequestsCard
 */
import { squashAtomCommandFailure } from "@t3tools/client-runtime/state/runtime";
import { useCallback, useState } from "react";

import { usePrimaryEnvironment } from "~/state/environments";
import { infinitusEnvironment } from "~/state/infinitus";
import { useEnvironmentQuery } from "~/state/query";
import { useAtomCommand } from "~/state/use-atom-command";

import { Button } from "../../ui/button";
import { SettingsSection, useRelativeTimeTick } from "../settingsLayout";
import { formatCountdown } from "./pairPhone.logic";
import { decisionNotice, pairingRequestRows } from "./pairingRequests.logic";

const EMPTY_NOTICE =
  "No phone is asking to pair. In the Infinitus app, add a connection, find this Mac on the network and choose “Ask to approve”.";

export function InfinitusPairingRequestsCard() {
  const environmentId = usePrimaryEnvironment()?.environmentId ?? null;
  const query = useEnvironmentQuery(
    environmentId === null ? null : infinitusEnvironment.pairing({ environmentId, input: {} }),
  );
  const requests = query.data ?? [];
  const decide = useAtomCommand(infinitusEnvironment.pairingDecide, { reportFailure: false });
  const [deciding, setDeciding] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  // The countdowns tick only while there is one to draw.
  const nowMs = useRelativeTimeTick(requests.length === 0 ? 60_000 : 1_000);
  const rows = pairingRequestRows(requests, nowMs);

  const settle = useCallback(
    async (id: string, approve: boolean) => {
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
    },
    [decide, environmentId],
  );

  return (
    <SettingsSection id="infinitus-pairing-requests" title="Pairing requests">
      <div className="flex flex-col gap-3 px-3 py-3 text-[13px] sm:px-4">
        {rows.length === 0 ? (
          <p role="status" className="text-muted-foreground">
            {EMPTY_NOTICE}
          </p>
        ) : (
          <ul className="flex flex-col gap-3">
            {rows.map((row) => (
              <li
                key={row.id}
                className="flex flex-wrap items-center gap-x-4 gap-y-2 rounded-lg border border-border/60 px-3 py-2"
              >
                <div className="flex min-w-0 flex-1 flex-col">
                  <span className="truncate font-medium text-foreground">{row.deviceName}</span>
                  {row.detail === null ? null : (
                    <span className="truncate text-muted-foreground">{row.detail}</span>
                  )}
                  <span className="text-muted-foreground">
                    Expires in{" "}
                    <span className="tabular-nums text-foreground">
                      {formatCountdown(row.secondsLeft)}
                    </span>
                  </span>
                </div>
                <span
                  className="font-mono text-2xl tracking-[0.2em] text-foreground"
                  aria-label={`Match code ${row.matchCode}`}
                >
                  {row.matchCode}
                </span>
                <div className="flex gap-2">
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
              </li>
            ))}
          </ul>
        )}
        {notice === null ? null : (
          <p role="alert" className="text-muted-foreground">
            {notice}
          </p>
        )}
      </div>
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
