import { Spinner } from "~/components/ui/spinner";
import type { ServerUpdateState } from "@infinitus/client-runtime/state/server";
import { CircleAlertIcon, DownloadIcon } from "lucide-react";

export function ComposerServerUpdateIcon({
  status,
}: {
  readonly status: ServerUpdateState["status"];
}) {
  if (status === "running") {
    return <Spinner aria-hidden />;
  }
  if (status === "failed") {
    return <CircleAlertIcon aria-hidden className="text-error" />;
  }
  return <DownloadIcon aria-hidden />;
}
<<<<<<< HEAD

/** One text line, clipped at the end so the error detail never squeezes its title. */
export function ComposerServerUpdateStatus({
  state,
  serverLabel = "server",
}: {
  readonly state: Exclude<ServerUpdateState, { status: "idle" }>;
  readonly serverLabel?: string;
}) {
  const [detailsOpen, setDetailsOpen] = useState(false);
  const triggerId = useId();
  const title = `${state.status === "failed" ? "Could not update" : "Updating"} ${serverLabel}`;
  const detail =
    state.status === "failed"
      ? state.message
      : serverUpdateStageLabel(state.stage, state.runningTurns);
  return (
    <span
      role={state.status === "failed" ? "alert" : "status"}
      className="min-w-0"
      data-composer-server-update-status={state.status}
    >
      <Tooltip open={detailsOpen} onOpenChange={setDetailsOpen} triggerId={triggerId}>
        <TooltipTrigger
          id={triggerId}
          closeOnClick={false}
          render={
            <button
              type="button"
              aria-label={`${title}: ${detail}`}
              className="block max-w-full cursor-help truncate rounded-sm text-left outline-none focus-visible:ring-2 focus-visible:ring-inset focus-visible:ring-ring"
              onClick={() => setDetailsOpen(true)}
            >
              {title}
              <ComposerBanner.Separator />
              <span className="font-normal text-muted-foreground">{detail}</span>
            </button>
          }
        />
        <TooltipPopup side="top">
          {title}: {detail}
        </TooltipPopup>
      </Tooltip>
    </span>
  );
}
=======
>>>>>>> upstream-sync-43879d970-upstream-renamed
