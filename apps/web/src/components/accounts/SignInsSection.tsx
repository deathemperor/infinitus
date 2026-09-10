import type { SignInRowModel } from "@t3tools/client-runtime/state/infinitusAccounts";

import { Button } from "../ui/button";
import { Spinner } from "../ui/spinner";
import { signInButtonLabel, signInStatus, waitingSessionsLabel } from "./signIns.logic";

/**
 * The AWS profiles and gcloud accounts whose credentials lapsed under a
 * session, each with a way to sign in again from here. Rendered only when
 * there is at least one; the page leaves it out otherwise.
 */
export function SignInsSection({
  rows,
  pendingKey,
  failure,
  onSignIn,
}: {
  readonly rows: ReadonlyArray<SignInRowModel>;
  readonly pendingKey: string | null;
  readonly failure: { readonly key: string; readonly message: string } | null;
  readonly onSignIn: (row: SignInRowModel) => void;
}) {
  return (
    <section className="flex flex-col gap-1">
      <h2 className="font-medium text-foreground text-sm">Sign-ins</h2>
      <p className="text-muted-foreground text-xs">
        Sessions stuck on expired credentials. Signing in runs on the Infinitus host.
      </p>
      <div className="flex flex-col">
        {rows.map((row) => {
          const label = signInButtonLabel(row);
          const sessions = waitingSessionsLabel(row.sessions);
          const pending = pendingKey === row.key;
          return (
            <div key={row.key} className="flex flex-col gap-1 border-b py-2 last:border-b-0">
              <div className="flex items-center gap-2">
                <span className="min-w-0 truncate text-sm">
                  <span className="text-muted-foreground">{row.toolLabel}</span>{" "}
                  <span className="font-medium text-foreground">{row.profile}</span>
                </span>
                {label === null ? null : (
                  <Button
                    className="ms-auto"
                    size="xs"
                    variant="outline"
                    aria-label={`${label}: ${row.toolLabel} ${row.profile}`}
                    aria-busy={pending}
                    disabled={pending}
                    onClick={() => onSignIn(row)}
                  >
                    {pending ? <Spinner className="size-3" /> : null}
                    {label}
                  </Button>
                )}
              </div>
              <p className="text-muted-foreground text-xs">{signInStatus(row)}</p>
              {row.phase === "waiting" && row.url !== null ? (
                <a
                  className="truncate text-xs underline underline-offset-2"
                  href={row.url}
                  target="_blank"
                  rel="noreferrer"
                >
                  {row.url}
                </a>
              ) : null}
              {sessions === "" ? null : (
                <p className="truncate text-muted-foreground text-xs">{sessions}</p>
              )}
              {failure?.key === row.key ? (
                <p className="text-destructive text-xs">{failure.message}</p>
              ) : null}
            </div>
          );
        })}
      </div>
    </section>
  );
}
