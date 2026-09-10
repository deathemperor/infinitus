import { useAtomValue } from "@effect/atom-react";
import { useNavigate } from "@tanstack/react-router";
import { UsersIcon } from "lucide-react";
import { memo, useMemo } from "react";

import { usePrimaryEnvironmentId } from "../../state/environments";
import { infinitusEnvironment } from "../../state/infinitus";
import { useEnvironmentQuery } from "../../state/query";
import { primaryServerConfigAtom } from "../../state/server";
import { Tooltip, TooltipPopup, TooltipTrigger } from "../ui/tooltip";
import { sidebarAccountsPillView } from "./sidebarAccountsPill.logic";

/**
 * The footer's Infinitus line: which account the primary environment's engines
 * are on and how full its tightest window is, or that Infinitus is offline.
 * Static by design — no animation, and the text is derived during render, so the
 * pill only repaints when the snapshot it reads changes.
 */
export const SidebarAccountsPill = memo(function SidebarAccountsPill() {
  const navigate = useNavigate();
  const environmentId = usePrimaryEnvironmentId();
  const capability = useAtomValue(primaryServerConfigAtom)?.environment.capabilities.infinitus;
  const snapshotQuery = useEnvironmentQuery(
    capability === true && environmentId !== null
      ? infinitusEnvironment.snapshot({ environmentId, input: {} })
      : null,
  );
  const snapshot = snapshotQuery.data;
  const view = useMemo(
    () => sidebarAccountsPillView({ capability, snapshot }),
    [capability, snapshot],
  );

  if (view === null) return null;

  return (
    <Tooltip>
      <TooltipTrigger
        render={
          view.offline ? (
            <div className="flex h-7 w-full items-center gap-2 rounded-lg bg-sidebar-control-surface px-2 text-muted-foreground text-xs font-medium">
              <UsersIcon className="size-3.5 shrink-0" aria-hidden />
              <span className="min-w-0 truncate">{view.text}</span>
            </div>
          ) : (
            <button
              type="button"
              aria-label={view.tooltip}
              className="flex h-7 w-full items-center gap-2 rounded-lg bg-sidebar-control-surface px-2 text-left text-sidebar-foreground text-xs font-medium hover:bg-sidebar-row-hover"
              onClick={() => void navigate({ to: "/accounts" })}
            >
              <UsersIcon className="size-3.5 shrink-0" aria-hidden />
              <span className="min-w-0 truncate">{view.text}</span>
            </button>
          )
        }
      />
      <TooltipPopup side="top">{view.tooltip}</TooltipPopup>
    </Tooltip>
  );
});
