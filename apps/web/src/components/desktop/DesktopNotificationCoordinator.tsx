import { scopeThreadRef } from "@t3tools/client-runtime/environment";
import { useNavigate, useParams } from "@tanstack/react-router";
import { useEffect, useRef } from "react";

import { useClientSettings } from "../../hooks/useSettings";
import {
  type SeenThread,
  attentionCount,
  threadNotifications,
} from "../../lib/desktopNotifications.logic";
import { windowInBackground } from "../../lib/infinitusCompletionSound.logic";
import { useThreadShells } from "../../state/entities";
import { usePrimaryEnvironment } from "../../state/environments";
import { infinitusEnvironment } from "../../state/infinitus";
import { useEnvironmentQuery } from "../../state/query";
import { buildThreadRouteParams, resolveThreadRouteRef } from "../../threadRoutes";
import { resolveSidebarThreadStatus } from "../Sidebar.logic";
import { heldEntryFor } from "../sidebar/infinitusHeld.logic";

/**
 * Posts the desktop's OS notifications and keeps the Dock badge (#270 B):
 * one banner per thread that moves into approval, input, held or failed (or,
 * off by default, finishes a turn), the badge counting the threads waiting
 * on the user, a click routing the window to the thread. Mounted once from
 * `__root.tsx`; nothing rendered; nothing on a shell without the bridge.
 * Holds are the primary environment's (the held stream is the local host's,
 * subscribed here); a thread on another environment is never read as held.
 */
export function DesktopNotificationCoordinator() {
  const bridge = window.desktopBridge;
  const postNotification = bridge?.postNotification;
  const setBadgeCount = bridge?.setBadgeCount;
  const onNotificationActivated = bridge?.onNotificationActivated;
  const shells = useThreadShells();
  const settings = useClientSettings();
  const navigate = useNavigate();
  const primary = usePrimaryEnvironment();
  const primaryEnvironmentId = primary?.environmentId ?? null;
  const primarySupported = primary?.serverConfig?.environment.capabilities.infinitus === true;
  const primaryHolds = useEnvironmentQuery(
    primaryEnvironmentId !== null && primarySupported && postNotification !== undefined
      ? infinitusEnvironment.holds({ environmentId: primaryEnvironmentId, input: {} })
      : null,
  ).data;
  const viewedRef = useParams({ strict: false, select: (params) => resolveThreadRouteRef(params) });
  const viewedKey = viewedRef === null ? null : `${viewedRef.environmentId}:${viewedRef.threadId}`;
  const seen = useRef<ReadonlyMap<string, SeenThread>>(new Map());
  const badge = useRef<number | null>(null);

  useEffect(() => {
    if (postNotification === undefined || setBadgeCount === undefined) return;
    const watched = shells.map((thread) => {
      const held = heldEntryFor(
        thread.environmentId === primaryEnvironmentId ? primaryHolds : null,
        thread.id,
      );
      return {
        environmentId: thread.environmentId,
        id: thread.id,
        title: thread.title,
        status: resolveSidebarThreadStatus(thread, {
          held: held?.kind === "held",
          limited: held?.kind === "limited",
        }),
        latestTurn: thread.latestTurn,
      };
    });
    const { requests, next } = threadNotifications(
      seen.current,
      watched,
      {
        approval: settings.desktopNotifyOnApproval,
        input: settings.desktopNotifyOnInput,
        held: settings.desktopNotifyOnHeld,
        failure: settings.desktopNotifyOnFailure,
        completion: settings.desktopNotifyOnCompletion,
      },
      { viewedKey: windowInBackground(document) ? null : viewedKey },
    );
    seen.current = next;
    for (const request of requests) void postNotification(request);
    const count = settings.desktopBadgeAttention ? attentionCount(watched) : 0;
    if (badge.current !== count) {
      badge.current = count;
      void setBadgeCount(count);
    }
  }, [
    postNotification,
    setBadgeCount,
    shells,
    primaryEnvironmentId,
    primaryHolds,
    settings,
    viewedKey,
  ]);

  useEffect(() => {
    if (onNotificationActivated === undefined) return;
    return onNotificationActivated((event) => {
      void navigate({
        to: "/$environmentId/$threadId",
        params: buildThreadRouteParams(scopeThreadRef(event.environmentId, event.threadId)),
      });
    });
  }, [onNotificationActivated, navigate]);

  return null;
}
