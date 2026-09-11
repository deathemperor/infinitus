import type { InfinitusStatus } from "@t3tools/contracts/infinitus";
import { Link } from "@tanstack/react-router";

import { buildEngineStatusRows } from "../settings/infinitus/panel.logic";
import { Badge } from "../ui/badge";
import { Button } from "../ui/button";
import {
  accountsEmptyMessage,
  accountsEmptyReason,
  accountsEmptyShowsSetupGuide,
  ACCOUNTS_SETUP_GUIDE_URL,
} from "./accountsEmpty.logic";

/**
 * What the page shows when the app answered but no engine reports a fleet:
 * which of the steps before an account row is missing, the engines the app
 * did report, and the two ways on — the Engines pane, and the setup guide
 * for a machine that has no engine to turn on yet.
 */
export function AccountsEmpty({ status }: { readonly status: InfinitusStatus | undefined }) {
  const rows = buildEngineStatusRows(status);
  const reason = accountsEmptyReason(rows);

  return (
    <section className="flex max-w-xl flex-col items-start gap-3 rounded-lg border p-4">
      <h2 className="font-medium text-foreground text-sm">No accounts yet</h2>
      <p className="text-muted-foreground text-sm">{accountsEmptyMessage(reason)}</p>
      {rows.length === 0 ? null : (
        <ul className="flex flex-col gap-1">
          {rows.map((row) => (
            <li key={row.key} className="flex items-center gap-1.5 text-sm">
              <span className="text-foreground">{row.label}</span>
              <Badge variant={row.enabled ? "default" : "outline"}>
                {row.enabled ? "On" : "Off"}
              </Badge>
              <Badge variant="outline">{row.registered ? "Registered" : "Not registered"}</Badge>
            </li>
          ))}
        </ul>
      )}
      <div className="flex flex-wrap items-start gap-2">
        <Button render={<Link to="/settings/infinitus/engines" />} size="sm" variant="outline">
          Open Engines
        </Button>
        {accountsEmptyShowsSetupGuide(reason) ? (
          <Button
            render={<a href={ACCOUNTS_SETUP_GUIDE_URL} target="_blank" rel="noopener noreferrer" />}
            size="sm"
            variant="outline"
          >
            Set up an engine
          </Button>
        ) : null}
      </div>
    </section>
  );
}
