import type {
  AccountAction,
  AccountRowModel,
  FleetSectionModel,
} from "@t3tools/client-runtime/state/infinitusAccounts";
import type { ExhaustedBandModel } from "@t3tools/client-runtime/state/infinitusExhausted";

import { Button } from "../ui/button";
import { Spinner } from "../ui/spinner";
import { AccountRow } from "./AccountRow";
import {
  addAccountBusy,
  addAccountButtonLabel,
  addAccountStatus,
  type AddAccountFlow,
} from "./addAccount.logic";
import { ExhaustedBand } from "./ExhaustedBand";

/** One engine's fleet: what it is, the warning it carries, and its accounts. */
export function FleetSection({
  section,
  band,
  pending,
  failure,
  offersAdd,
  addFlow,
  signInRunning,
  onAction,
  onAdd,
}: {
  readonly section: FleetSectionModel;
  /** The all-exhausted band, when every unheld account is at a limit. */
  readonly band: ExhaustedBandModel | null;
  readonly pending: { readonly number: number; readonly action: AccountAction } | null;
  readonly failure: { readonly number: number; readonly message: string } | null;
  /** The running build lists the `add` verb at all. */
  readonly offersAdd: boolean;
  /** The sign-in the page started on this fleet, if any. */
  readonly addFlow: AddAccountFlow | null;
  /** The app's word that some sign-in is running right now. */
  readonly signInRunning: boolean;
  readonly onAction: (row: AccountRowModel, action: AccountAction, alias?: string) => void;
  /** Starts the fleet's sign-in: a new account, or the row to sign in again as. */
  readonly onAdd: (target: AccountRowModel | null) => void;
}) {
  const canAdd = offersAdd && section.canAdd;
  const busy = addAccountBusy(addFlow, signInRunning);
  const status = canAdd ? addAccountStatus(addFlow, signInRunning) : null;
  return (
    <section className="flex flex-col gap-1">
      <div className="flex flex-wrap items-center gap-2">
        <h2 className="font-medium text-foreground text-sm">{section.title}</h2>
        {canAdd ? (
          <Button
            className="ms-auto"
            size="xs"
            variant="outline"
            aria-label={`${addAccountButtonLabel(null)}: ${section.title}`}
            aria-busy={busy}
            disabled={busy}
            onClick={() => onAdd(null)}
          >
            {addFlow !== null && busy ? <Spinner className="size-3" /> : null}
            {addAccountButtonLabel(null)}
          </Button>
        ) : null}
      </div>
      {section.caveat === null ? null : (
        <p className="text-muted-foreground text-xs">{section.caveat}</p>
      )}
      {status === null ? null : (
        <p
          role="status"
          className={
            addFlow?.phase.kind === "failed"
              ? "text-destructive text-xs"
              : "text-muted-foreground text-xs"
          }
        >
          {status}
        </p>
      )}
      {band === null ? null : <ExhaustedBand band={band} />}
      <div className="flex flex-col">
        {section.rows.map((row) => (
          <AccountRow
            key={row.number}
            row={row}
            pendingAction={pending?.number === row.number ? pending.action : null}
            failure={failure?.number === row.number ? failure.message : null}
            onAction={(action, alias) => onAction(row, action, alias)}
            onRelogin={canAdd && row.reloginNeeded ? () => onAdd(row) : undefined}
            reloginBusy={busy}
          />
        ))}
      </div>
    </section>
  );
}
