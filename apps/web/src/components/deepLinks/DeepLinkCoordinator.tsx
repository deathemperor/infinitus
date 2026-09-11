import { scopeProjectRef } from "@t3tools/client-runtime/environment";
import type { DesktopDeepLink } from "@t3tools/contracts";
import { useNavigate } from "@tanstack/react-router";
import { useEffect, useEffectEvent, useRef } from "react";

import { useComposerDraftStore } from "../../composerDraftStore";
import { useNewThreadHandler } from "../../hooks/useHandleNewThread";
import { readProjects } from "../../state/entities";
import { usePrimaryEnvironment } from "../../state/environments";
import { useEnvironmentQuery } from "../../state/query";
import { environmentShell } from "../../state/shell";
import { buildThreadRouteParams, resolveThreadRouteRef } from "../../threadRoutes";
import { toastManager } from "../ui/toast";
import { resolveDeepLinkProject } from "./deepLink.logic";
import { usePendingTeamJoinStore } from "./pendingTeamJoin";

/**
 * Mounted once in the app shell (#270 D): the link the desktop was opened
 * with. The shell keeps only the latest one; this pulls it once the primary
 * environment is connected, and again on every ping, so a link that landed
 * during startup and one that lands while the window is up take the same
 * path. `thread` navigates; `new` opens the composer on the project's
 * default env mode with the prompt prefilled and never sends it.
 */
export function DeepLinkCoordinator() {
  const primaryEnvironment = usePrimaryEnvironment();
  const handleNewThread = useNewThreadHandler();
  const navigate = useNavigate();
  const queueRef = useRef(Promise.resolve());
  const shell = useEnvironmentQuery(
    primaryEnvironment === null
      ? null
      : environmentShell.stateAtom(primaryEnvironment.environmentId),
  );
  const ready =
    primaryEnvironment?.connection.phase === "connected" &&
    primaryEnvironment.serverConfig !== null &&
    shell.data?.snapshot._tag === "Some";

  const open = useEffectEvent(async (link: DesktopDeepLink) => {
    if (link.kind === "thread") {
      const ref = resolveThreadRouteRef(link);
      if (ref === null) return;
      await navigate({ to: "/$environmentId/$threadId", params: buildThreadRouteParams(ref) });
      return;
    }
    if (link.kind === "join") {
      // The code goes to the Team page's Join field and leaves only when the
      // user presses Request to join; nothing joins on its own.
      usePendingTeamJoinStore.getState().offer(link.link);
      await navigate({ to: "/settings/infinitus/team" });
      return;
    }
    const project = resolveDeepLinkProject(readProjects(), link.project);
    if (project === null) {
      toastManager.add({
        type: "error",
        title: "No project matches the link",
        description: `Nothing is named "${link.project}" by id, title, or folder.`,
      });
      return;
    }
    const created = await handleNewThread(scopeProjectRef(project.environmentId, project.id));
    if (created !== null && link.prompt.length > 0) {
      useComposerDraftStore.getState().setPrompt(created.draftId, link.prompt);
    }
  });

  useEffect(() => {
    const bridge = typeof window === "undefined" ? undefined : window.desktopBridge;
    if (
      !ready ||
      typeof bridge?.consumePendingDeepLink !== "function" ||
      typeof bridge.onDeepLinkPending !== "function"
    ) {
      return;
    }
    const consume = bridge.consumePendingDeepLink;
    const pull = () => {
      queueRef.current = queueRef.current
        .then(async () => {
          const link = await consume();
          if (link !== null) await open(link);
        })
        .catch(() => undefined);
    };
    const unsubscribe = bridge.onDeepLinkPending(pull);
    pull();
    return unsubscribe;
  }, [ready]);

  return null;
}
