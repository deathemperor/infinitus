import { useEffect, useRef } from "react";

import { useClientSettings } from "../../hooks/useSettings";
import { attentionCount } from "../../lib/infinitusNotifications.logic";
import { useThreadShells } from "../../state/entities";
import { resolveSidebarThreadStatus } from "../Sidebar.logic";

/**
 * Keeps the Dock badge (#270 B): the count of threads waiting for an
 * approval or an answer. Mounted once from `__root.tsx`; nothing rendered;
 * nothing on a shell without the bridge. Banners are upstream's
 * `ThreadNotificationCoordinator` (#1032).
 */
export function DesktopBadgeCoordinator() {
  const setBadgeCount = window.desktopBridge?.setBadgeCount;
  const shells = useThreadShells();
  const enabled = useClientSettings((settings) => settings.desktopBadgeAttention);
  const badge = useRef<number | null>(null);

  useEffect(() => {
    if (setBadgeCount === undefined) return;
    const count = enabled
      ? attentionCount(shells.map((thread) => ({ status: resolveSidebarThreadStatus(thread) })))
      : 0;
    if (badge.current !== count) {
      badge.current = count;
      void setBadgeCount(count);
    }
  }, [setBadgeCount, shells, enabled]);

  return null;
}
