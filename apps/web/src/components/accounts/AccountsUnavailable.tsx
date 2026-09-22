import type { EnvironmentPresentation } from "../../state/environments";
import { InfinitusLaunchButton } from "../settings/infinitus/InfinitusLaunchButton";
import { Button } from "../ui/button";

/**
 * What the page shows when the control socket never answered: the reason the
 * server gave, where it looked when it knows, and a retry that re-runs the
 * subscription rather than asking the socket again from here.
 */
export function AccountsUnavailable({
  environment,
  reason,
  socketPath,
  onRetry,
}: {
  /** The machine whose socket is quiet; its own app is the one to launch.
      The primary-only pages leave it out and get the primary. */
  readonly environment?: EnvironmentPresentation;
  readonly reason: string | null;
  readonly socketPath: string | null;
  readonly onRetry: () => void;
}) {
  return (
    <section className="flex max-w-xl flex-col items-start gap-2 rounded-lg border p-4">
      <h3 className="font-medium text-foreground text-sm">Infinitus is offline</h3>
      <p className="text-muted-foreground text-sm">
        {reason ?? "The control socket did not answer."}
      </p>
      {socketPath === null ? null : (
        <p className="break-all font-mono text-muted-foreground text-xs">{socketPath}</p>
      )}
      <div className="flex flex-wrap items-start gap-2">
        <InfinitusLaunchButton {...(environment === undefined ? {} : { environment })} />
        <Button size="sm" variant="outline" onClick={onRetry}>
          Retry
        </Button>
      </div>
    </section>
  );
}
