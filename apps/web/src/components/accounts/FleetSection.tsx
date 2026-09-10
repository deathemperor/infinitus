import type {
  AccountAction,
  AccountRowModel,
  FleetSectionModel,
} from "@t3tools/client-runtime/state/infinitusAccounts";

import { AccountRow } from "./AccountRow";

/** One engine's fleet: what it is, the warning it carries, and its accounts. */
export function FleetSection({
  section,
  pending,
  failure,
  onAction,
}: {
  readonly section: FleetSectionModel;
  readonly pending: { readonly number: number; readonly action: AccountAction } | null;
  readonly failure: { readonly number: number; readonly message: string } | null;
  readonly onAction: (row: AccountRowModel, action: AccountAction, alias?: string) => void;
}) {
  return (
    <section className="flex flex-col gap-1">
      <h2 className="font-medium text-foreground text-sm">{section.title}</h2>
      {section.caveat === null ? null : (
        <p className="text-muted-foreground text-xs">{section.caveat}</p>
      )}
      <div className="flex flex-col">
        {section.rows.map((row) => (
          <AccountRow
            key={row.number}
            row={row}
            pendingAction={pending?.number === row.number ? pending.action : null}
            failure={failure?.number === row.number ? failure.message : null}
            onAction={(action, alias) => onAction(row, action, alias)}
          />
        ))}
      </div>
    </section>
  );
}
