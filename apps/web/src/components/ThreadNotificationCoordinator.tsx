import { useAtomValue } from "@effect/atom-react";
import { useNavigate, useParams } from "@tanstack/react-router";
import type { EnvironmentId, ThreadId } from "@infinitus/contracts";
import * as Option from "effect/Option";
import {
  CircleAlertIcon,
  CircleCheckIcon,
  MessageCircleQuestionIcon,
  ShieldQuestionIcon,
} from "lucide-react";
import { useCallback, useEffect, useRef } from "react";

import { getClientSettings, useClientSettings } from "../hooks/useSettings";
import {
  attentionNotificationTitle,
  notificationKind,
  quietForViewer,
  type ThreadNotificationRecord,
} from "../lib/infinitusNotifications.logic";
import { useEnvironment, useEnvironments } from "../state/environments";
import { infinitusEnvironment } from "../state/infinitus";
import { useEnvironmentQuery } from "../state/query";
import { environmentShell } from "../state/shell";
import {
  hasDesktopNotifications,
  hasNotificationSound,
  playNotificationSound,
  setNotificationBadge,
  unlockNotificationAudio,
} from "../threadNotifications";
import { resolveSidebarThreadStatus } from "./Sidebar.logic";
import { heldEntryFor } from "./sidebar/infinitusHeld.logic";
import { toastManager } from "./ui/toast";

export function ThreadNotificationCoordinator() {
  const { environments } = useEnvironments();
  const mode = useClientSettings((settings) => settings.notificationMode);
  const inAppNotificationsEnabled = useClientSettings(
    (settings) => settings.inAppNotificationsEnabled,
  );
  const pending = useRef(
    new Map<string, { environmentId: EnvironmentId; notification: Notification }>(),
  );
  const onNotification = useCallback((environmentId: EnvironmentId, notification: Notification) => {
    pending.current.get(notification.tag)?.notification.close();
    pending.current.set(notification.tag, { environmentId, notification });
    setNotificationBadge(pending.current.size);
  }, []);

  useEffect(() => {
    const activeIds = new Set(environments.map(({ environmentId }) => environmentId));
    const count = pending.current.size;
    for (const [tag, { environmentId, notification }] of pending.current) {
      if (activeIds.has(environmentId)) continue;
      notification.close();
      pending.current.delete(tag);
    }
    if (count !== pending.current.size) setNotificationBadge(pending.current.size);
  }, [environments]);

  useEffect(() => {
    const clear = () => {
      for (const { notification } of pending.current.values()) notification.close();
      pending.current.clear();
      setNotificationBadge(0);
    };
    clear();
    if (!hasDesktopNotifications(mode)) return;
    const unsubscribe = window.desktopBridge?.onNotificationBadgeClear?.(clear);
    window.addEventListener("focus", clear);
    return () => {
      unsubscribe?.();
      window.removeEventListener("focus", clear);
      clear();
    };
  }, [mode]);

  useEffect(() => {
    if (!hasNotificationSound(mode)) return;
    document.addEventListener("pointerdown", unlockNotificationAudio);
    document.addEventListener("keydown", unlockNotificationAudio);
    return () => {
      document.removeEventListener("pointerdown", unlockNotificationAudio);
      document.removeEventListener("keydown", unlockNotificationAudio);
    };
  }, [mode]);

  if (mode === "off" && !inAppNotificationsEnabled) return null;

  return environments.map((environment) => (
    <EnvironmentNotifications
      key={environment.environmentId}
      environmentId={environment.environmentId}
      onNotification={onNotification}
    />
  ));
}

function EnvironmentNotifications({
  environmentId,
  onNotification,
}: {
  environmentId: EnvironmentId;
  onNotification: (environmentId: EnvironmentId, notification: Notification) => void;
}) {
  const shell = useAtomValue(environmentShell.stateValueAtom(environmentId));
  const mode = useClientSettings((settings) => settings.notificationMode);
  const inAppNotificationsEnabled = useClientSettings(
    (settings) => settings.inAppNotificationsEnabled,
  );
  const navigate = useNavigate();
  const { environmentId: activeEnvironmentId, threadId: activeThreadId } = useParams({
    strict: false,
  });
  // Fork (#1032): held and limited threads notify too, from the server's own
  // holds stream. Upstream has no such state, so it has no title for one.
  const supported =
    useEnvironment(environmentId)?.serverConfig?.environment.capabilities.infinitus === true;
  const holds = useEnvironmentQuery(
    supported ? infinitusEnvironment.holds({ environmentId, input: {} }) : null,
  ).data;
  const viewedKey =
    activeEnvironmentId === undefined || activeThreadId === undefined
      ? null
      : `${activeEnvironmentId}:${activeThreadId}`;
  const previous = useRef(new Map<ThreadId, ThreadNotificationRecord>());

  useEffect(() => {
    if (shell.status !== "live" || Option.isNone(shell.snapshot)) {
      previous.current.clear();
      return;
    }
    const next = new Map<ThreadId, ThreadNotificationRecord>();
    for (const thread of shell.snapshot.value.threads) {
      const held = heldEntryFor(holds, thread.id);
      let status = resolveSidebarThreadStatus(thread, {
        held: held?.kind === "held",
        limited: held?.kind === "limited",
      });
      // Upstream's own failure check reads the latest TURN; the fork's
      // resolver reads the SESSION. They catch different rows, so both run.
      if (status === "ready" && thread.latestTurn?.state === "error") status = "failed";
      const prior = previous.current.get(thread.id);
      // `attention` is the banner TITLE here, not upstream's dedupe key —
      // the fork titles `held`, which upstream has no word for. `input` is
      // the key, and is what `ThreadNotificationRecord` compares.
      const attention = attentionNotificationTitle(status);
      const input = attention === null ? null : `${thread.latestTurn?.turnId ?? ""}:${status}`;
      const completedAt = Date.parse(thread.latestTurn?.completedAt ?? "");
      const completion =
        status === "ready" &&
        thread.latestTurn?.state === "completed" &&
        Number.isFinite(completedAt)
          ? completedAt
          : (prior?.completion ?? null);
      next.set(thread.id, { input, completion });
      if (!prior || (mode === "off" && !inAppNotificationsEnabled) || thread.archivedAt !== null)
        continue;
      // Fork (#270 B): a completion with turns still queued is not the end —
      // the drain sends the next row the moment the turn ends.
      const kind = notificationKind(prior, { input, completion }, thread.queuedTurns?.length ?? 0);
      if (!kind) continue;
      // Fork (#1032): the thread on screen stays quiet — no toast, no banner
      // and no bell — while the window has focus. Upstream silences only its
      // banner and toast for it, and still rings.
      if (quietForViewer(viewedKey, `${environmentId}:${thread.id}`, document)) continue;
      const title = kind === "completion" ? "Thread completed" : (attention ?? "Input needed");
      if (hasNotificationSound(mode)) {
        void playNotificationSound(kind, () =>
          hasNotificationSound(getClientSettings().notificationMode),
        );
      }
      if (
        inAppNotificationsEnabled &&
        document.visibilityState === "visible" &&
        document.hasFocus() &&
        (activeEnvironmentId !== environmentId || activeThreadId !== thread.id)
      ) {
        const toastId = toastManager.add({
          type: kind === "completion" ? "success" : status === "failed" ? "error" : "warning",
          title,
          description: thread.title,
          data: {
            hideCopyButton: true,
            leadingIcon:
              kind === "completion" ? (
                <CircleCheckIcon
                  aria-hidden
                  className="size-4 text-emerald-700 dark:text-emerald-300"
                />
              ) : status === "approval" ? (
                <ShieldQuestionIcon
                  aria-hidden
                  className="size-4 text-amber-700 dark:text-amber-300"
                />
              ) : status === "failed" ? (
                <CircleAlertIcon aria-hidden className="size-4 text-red-700 dark:text-red-300" />
              ) : (
                <MessageCircleQuestionIcon
                  aria-hidden
                  className="size-4 text-indigo-600 dark:text-indigo-300"
                />
              ),
          },
          actionProps: {
            children: "Open thread",
            onClick: () => {
              toastManager.close(toastId);
              void navigate({
                to: "/$environmentId/$threadId",
                params: { environmentId, threadId: thread.id },
              });
            },
          },
        });
        continue;
      }
      if (
        !hasDesktopNotifications(mode) ||
        (document.visibilityState === "visible" && document.hasFocus()) ||
        typeof Notification === "undefined" ||
        Notification.permission !== "granted"
      )
        continue;
      try {
        const notification = new Notification(title, {
          body: thread.title,
          tag: `${environmentId}:${thread.id}`,
          silent: true,
        });
        onNotification(environmentId, notification);
        notification.addEventListener("click", () => {
          notification.close();
          window.focus();
          void navigate({
            to: "/$environmentId/$threadId",
            params: { environmentId, threadId: thread.id },
          });
        });
      } catch {
        // Some browsers expose Notification but reject desktop presentation.
      }
    }
    previous.current = next;
  }, [
    activeEnvironmentId,
    activeThreadId,
    environmentId,
    holds,
    inAppNotificationsEnabled,
    mode,
    navigate,
    onNotification,
    shell,
    viewedKey,
  ]);

  return null;
}
