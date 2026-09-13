import { useAtomValue } from "@effect/atom-react";
import { useNavigate, useParams } from "@tanstack/react-router";
import type { EnvironmentId, ThreadId } from "@t3tools/contracts";
import * as Option from "effect/Option";
import { useEffect, useRef } from "react";

import { getClientSettings, useClientSettings } from "../hooks/useSettings";
import { attentionNotificationTitle, quietForViewer } from "../lib/infinitusNotifications.logic";
import { useEnvironment, useEnvironments } from "../state/environments";
import { infinitusEnvironment } from "../state/infinitus";
import { useEnvironmentQuery } from "../state/query";
import { environmentShell } from "../state/shell";
import {
  hasDesktopNotifications,
  hasNotificationSound,
  playNotificationSound,
  unlockNotificationAudio,
} from "../threadNotifications";
import { resolveSidebarThreadStatus } from "./Sidebar.logic";
import { heldEntryFor } from "./sidebar/infinitusHeld.logic";

export function ThreadNotificationCoordinator() {
  const { environments } = useEnvironments();
  const mode = useClientSettings((settings) => settings.notificationMode);

  useEffect(() => {
    if (!hasNotificationSound(mode)) return;
    document.addEventListener("pointerdown", unlockNotificationAudio);
    document.addEventListener("keydown", unlockNotificationAudio);
    return () => {
      document.removeEventListener("pointerdown", unlockNotificationAudio);
      document.removeEventListener("keydown", unlockNotificationAudio);
    };
  }, [mode]);

  if (mode === "off") return null;

  return environments.map((environment) => (
    <EnvironmentNotifications
      key={environment.environmentId}
      environmentId={environment.environmentId}
    />
  ));
}

function EnvironmentNotifications({ environmentId }: { environmentId: EnvironmentId }) {
  const shell = useAtomValue(environmentShell.stateValueAtom(environmentId));
  const mode = useClientSettings((settings) => settings.notificationMode);
  const navigate = useNavigate();
  // Fork (#1032): held and failed threads notify too (the holds come from the
  // server's stream), and the thread on screen stays quiet while the window
  // has focus.
  const supported =
    useEnvironment(environmentId)?.serverConfig?.environment.capabilities.infinitus === true;
  const holds = useEnvironmentQuery(
    supported ? infinitusEnvironment.holds({ environmentId, input: {} }) : null,
  ).data;
  const viewedEnvironmentId = useParams({
    strict: false,
    select: (params) => params.environmentId,
  });
  const viewedThreadId = useParams({ strict: false, select: (params) => params.threadId });
  const viewedKey =
    viewedEnvironmentId === undefined || viewedThreadId === undefined
      ? null
      : `${viewedEnvironmentId}:${viewedThreadId}`;
  const previous = useRef(new Map<ThreadId, { input: string | null; completion: number | null }>());

  useEffect(() => {
    if (shell.status !== "live" || Option.isNone(shell.snapshot)) {
      previous.current.clear();
      return;
    }
    const next = new Map<ThreadId, { input: string | null; completion: number | null }>();
    for (const thread of shell.snapshot.value.threads) {
      const held = heldEntryFor(holds, thread.id);
      const status = resolveSidebarThreadStatus(thread, {
        held: held?.kind === "held",
        limited: held?.kind === "limited",
      });
      const prior = previous.current.get(thread.id);
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
      if (!prior || mode === "off" || thread.archivedAt !== null) continue;
      const kind =
        input && input !== prior.input
          ? "input"
          : completion !== null && (prior.completion === null || completion > prior.completion)
            ? "completion"
            : null;
      if (!kind) continue;
      if (quietForViewer(viewedKey, `${environmentId}:${thread.id}`, document)) continue;
      if (hasNotificationSound(mode)) {
        void playNotificationSound(kind, () =>
          hasNotificationSound(getClientSettings().notificationMode),
        );
      }
      if (
        !hasDesktopNotifications(mode) ||
        typeof Notification === "undefined" ||
        Notification.permission !== "granted"
      )
        continue;
      try {
        const notification = new Notification(
          kind === "completion" ? "Thread completed" : (attention ?? "Input needed"),
          { body: thread.title, tag: `${environmentId}:${thread.id}`, silent: true },
        );
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
  }, [environmentId, holds, mode, navigate, shell, viewedKey]);

  return null;
}
