import { InfinitusLaunchButton } from "../settings/infinitus/InfinitusLaunchButton";
import { Button } from "../ui/button";

/**
 * What the page shows when the control socket never answered: the reason the
 * server gave, where it looked when it knows, and a retry that re-runs the
 * subscription rather than asking the socket again from here.
 */
export function AccountsUnavailable({
  reason,
  socketPath,
  onRetry,
}: {
  readonly reason: string | null;
  readonly socketPath: string | null;
  readonly onRetry: () => void;
}) {
  return (
    <section className="flex max-w-xl flex-col items-start gap-2 rounded-lg border p-4">
      <h2 className="font-medium text-foreground text-sm">Infinitus is offline</h2>
      <p className="text-muted-foreground text-sm">
        {reason ?? "The control socket did not answer."}
      </p>
      {socketPath === null ? null : (
        <p className="break-all font-mono text-muted-foreground text-xs">{socketPath}</p>
      )}
      <div className="flex flex-wrap items-start gap-2">
        <InfinitusLaunchButton />
        <Button size="sm" variant="outline" onClick={onRetry}>
          Retry
        </Button>
      </div>
    </section>
  );
}
