import { ChartLineIcon, GaugeIcon, UsersIcon } from "lucide-react";
import type { ReactNode } from "react";
import { useNavigate } from "@tanstack/react-router";

import { useInfinitusSupported } from "~/hooks/useInfinitusSupported";
import { SidebarMenuButton, SidebarMenuItem } from "../ui/sidebar";
import { Tooltip, TooltipPopup, TooltipTrigger } from "../ui/tooltip";

/**
 * The fork's sidebar utility items beside upstream's Settings, Pull Requests
 * and Usage: Accounts and Utilization behind the `infinitus` capability
 * (the pages read a connected Mac's app), Stats (#659) everywhere.
 */
export function InfinitusSidebarUtilityItems({
  onBeforeNavigate,
}: {
  /** Closes the mobile sidebar, the way upstream's own items do. */
  onBeforeNavigate: () => void;
}) {
  const navigate = useNavigate();
  const infinitusSupported = useInfinitusSupported();
  const open = (to: "/accounts" | "/stats" | "/utilization") => {
    onBeforeNavigate();
    void navigate({ to });
  };
  return (
    <>
      {infinitusSupported ? (
        <UtilityItem icon={<UsersIcon />} label="Accounts" onClick={() => open("/accounts")} />
      ) : null}
      <UtilityItem icon={<ChartLineIcon />} label="Stats" onClick={() => open("/stats")} />
      {infinitusSupported ? (
        <UtilityItem
          icon={<GaugeIcon />}
          label="Utilization"
          onClick={() => open("/utilization")}
        />
      ) : null}
    </>
  );
}

// The same shape as upstream's private `SidebarUtilityItem` in
// `SidebarChrome.tsx`; a copy, so that file keeps a single registration line.
function UtilityItem({
  icon,
  label,
  onClick,
}: {
  icon: ReactNode;
  label: string;
  onClick: () => void;
}) {
  return (
    <SidebarMenuItem className="shrink-0">
      <Tooltip>
        <TooltipTrigger
          render={
            <SidebarMenuButton aria-label={label} onClick={onClick} size="icon">
              {icon}
            </SidebarMenuButton>
          }
        />
        <TooltipPopup side="top">{label}</TooltipPopup>
      </Tooltip>
    </SidebarMenuItem>
  );
}
