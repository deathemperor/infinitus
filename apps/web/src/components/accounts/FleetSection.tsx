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
import { signInBusy, signInEnded, signInStatusText, type SignInFlow } from "./signIn.logic";

/** The in-app sign-in (#677) as the page hands it to a fleet: whether the
    build offers it, whether this client can show it, the flow on this fleet. */
export interface FleetSignIn {
  readonly offers: boolean;
  readonly inApp: boolean;
  readonly flow: SignInFlow | null;
  readonly onStart: (target: AccountRowModel | null) => void;
  readonly onCancel: () => void;
  readonly onSubmitCode: (code: string) => void;
}

/** One engine's fleet: what it is, the warning it carries, and its accounts. */
export function FleetSection({
  section,
  band,
  pending,
  failure,
  offersAdd,
  addFlow,
  signInRunning,
  signIn,
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
  readonly signIn: FleetSignIn;
  readonly onAction: (row: AccountRowModel, action: AccountAction, alias?: string) => void;
  /** Starts the fleet's sign-in: a new account, or the row to sign in again as. */
  readonly onAdd: (target: AccountRowModel | null) => void;
}) {
  // The in-app sign-in when the build has it (#677; every client since #747:
  // the shell's window, or a link and the code over the secret RPC); an
  // older build keeps the sign-in on the Mac (#672).
  const inApp = signIn.offers && signIn.inApp && section.canAdd;
  const canAdd = !signIn.offers && offersAdd && section.canAdd;
  const busy = inApp
    ? signInBusy(signIn.flow) || signInRunning
    : addAccountBusy(addFlow, signInRunning);
  const status = inApp
    ? signIn.flow === null
      ? signInRunning
        ? "A sign-in is already running in Infinitus."
        : null
      : signInStatusText(signIn.flow)
    : canAdd
      ? addAccountStatus(addFlow, signInRunning)
      : null;
  const failed = inApp ? signIn.flow?.phase === "failed" : addFlow?.phase.kind === "failed";
  const onStart = inApp ? signIn.onStart : onAdd;
  const codeField =
    inApp && signIn.flow !== null && signIn.flow.phase === "waitingForCode" && signIn.flow.pasteCode
      ? signIn.flow
      : null;
  const cancellable = inApp && signIn.flow !== null && !signInEnded(signIn.flow.phase);
  /** The provider's page to open from this device, while the flow waits for it. */
  const signInUrl = cancellable && signIn.flow?.url != null ? signIn.flow.url : null;
  return (
    <section className="flex flex-col gap-1">
      <div className="flex flex-wrap items-center gap-2">
        <h2 className="font-medium text-foreground text-sm">{section.title}</h2>
        {canAdd || inApp ? (
          <Button
            className="ms-auto"
            size="xs"
            variant="outline"
            aria-label={`${addAccountButtonLabel(null)}: ${section.title}`}
            aria-busy={busy}
            disabled={busy}
            onClick={() => onStart(null)}
          >
            {(inApp ? signIn.flow !== null : addFlow !== null) && busy ? (
              <Spinner className="size-3" />
            ) : null}
            {addAccountButtonLabel(null)}
          </Button>
        ) : null}
        {cancellable ? (
          <Button
            size="xs"
            variant="ghost"
            aria-label={`Cancel sign-in: ${section.title}`}
            onClick={signIn.onCancel}
          >
            Cancel
          </Button>
        ) : null}
      </div>
      {signInUrl === null ? null : (
        <a
          href={signInUrl}
          target="_blank"
          rel="noopener noreferrer"
          className="text-xs underline underline-offset-2"
          aria-label={`Open the sign-in page: ${section.title}`}
        >
          Open the sign-in page
        </a>
      )}
      {section.caveat === null ? null : (
        <p className="text-muted-foreground text-xs">{section.caveat}</p>
      )}
      {status === null ? null : (
        <p
          role="status"
          className={failed ? "text-destructive text-xs" : "text-muted-foreground text-xs"}
        >
          {status}
        </p>
      )}
      {codeField === null ? null : (
        <form
          className="flex flex-wrap items-center gap-2"
          onSubmit={(event) => {
            event.preventDefault();
            // Duck-typed, not `instanceof HTMLInputElement`: the unit suite
            // runs in node, where that global does not exist.
            const field = event.currentTarget.elements.namedItem("code");
            if (field !== null && "value" in field && typeof field.value === "string") {
              signIn.onSubmitCode(field.value);
              field.value = "";
            }
          }}
        >
          {/* A secret (#747): masked, never remembered, cleared on submit. */}
          <input
            name="code"
            type="password"
            autoComplete="off"
            spellCheck={false}
            aria-label={`Sign-in code: ${section.title}`}
            placeholder="Paste the code"
            disabled={codeField.codeBusy}
            className="h-7 min-w-0 flex-1 rounded-md border bg-background px-2 font-mono text-xs"
          />
          <Button
            type="submit"
            size="xs"
            disabled={codeField.codeBusy}
            aria-busy={codeField.codeBusy}
          >
            {codeField.codeBusy ? <Spinner className="size-3" /> : null}
            Submit code
          </Button>
          {codeField.codeError === null ? null : (
            <p role="alert" className="basis-full text-destructive text-xs">
              {codeField.codeError}
            </p>
          )}
        </form>
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
            onRelogin={(canAdd || inApp) && row.reloginNeeded ? () => onStart(row) : undefined}
            reloginBusy={busy}
          />
        ))}
      </div>
    </section>
  );
}
