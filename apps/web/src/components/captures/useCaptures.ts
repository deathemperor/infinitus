import { squashAtomCommandFailure } from "@t3tools/client-runtime/state/runtime";
import type { EnvironmentId, ProjectId, ResolvedKeybindingsConfig } from "@t3tools/contracts";
import { useParams } from "@tanstack/react-router";
import { useCallback, useEffect, useMemo } from "react";

import { isCommandPaletteOpen } from "../../commandPaletteBus";
import { useComposerDraftStore } from "../../composerDraftStore";
import { resolveShortcutCommand } from "../../keybindings";
import { getTerminalFocusOwner } from "../../lib/terminalFocus";
import { captures } from "../../state/captures";
import { useThread } from "../../state/entities";
import { useAtomCommand } from "../../state/use-atom-command";
import { resolveThreadRouteTarget } from "../../threadRoutes";
import { toastManager } from "../ui/toast";
import { captureApplyFailureMessage, captureText } from "./captures.logic";
import { useCapturesUiStore } from "./capturesUiStore";

export interface ActiveProjectRef {
  readonly environmentId: EnvironmentId;
  readonly projectId: ProjectId;
}

/**
 * The project the routed thread — or the draft, once a project is chosen —
 * belongs to. Null on a draft with no project yet.
 *
 * Reads the route as three strings rather than through `useHandleNewThread`:
 * that hook's `useParams` selector builds a new target object on every
 * render, which React counts as a changed store snapshot.
 * A component reading it can then never bail out of a same-state update,
 * and the composer's every-render layout measure turned that into a
 * synchronous update loop (#821). Chat-route components read this hook
 * once and pass the ref down.
 */
export function useActiveProjectRef(): ActiveProjectRef | null {
  const environmentId = useParams({ strict: false, select: (params) => params.environmentId });
  const threadId = useParams({ strict: false, select: (params) => params.threadId });
  const draftId = useParams({ strict: false, select: (params) => params.draftId });
  const routeTarget = useMemo(
    () => resolveThreadRouteTarget({ environmentId, threadId, draftId }),
    [draftId, environmentId, threadId],
  );
  const activeThread = useThread(routeTarget?.kind === "server" ? routeTarget.threadRef : null);
  const draftThread = useComposerDraftStore((store) =>
    routeTarget === null
      ? null
      : routeTarget.kind === "server"
        ? store.getDraftThread(routeTarget.threadRef)
        : store.getDraftSession(routeTarget.draftId),
  );
  const thread = activeThread ?? draftThread;
  if (!thread) return null;
  return { environmentId: thread.environmentId, projectId: thread.projectId };
}

/** Adds one capture to a project, toasting a refusal. */
export function useAddCapture() {
  const apply = useAtomCommand(captures.apply, { reportFailure: false });
  return useCallback(
    async (raw: string, project: ActiveProjectRef): Promise<boolean> => {
      const text = captureText(raw);
      if (text === null) return false;
      const result = await apply({
        environmentId: project.environmentId,
        input: { projectId: project.projectId, command: { type: "add", text } },
      });
      if (result._tag === "Success") return true;
      toastManager.add({
        type: "error",
        title: "Capture not saved",
        description: captureApplyFailureMessage(squashAtomCommandFailure(result)),
      });
      return false;
    },
    [apply],
  );
}

/** The current in-app selection, or null when nothing is selected. */
function selectedText(): string | null {
  if (typeof window === "undefined") return null;
  return captureText(window.getSelection()?.toString());
}

/**
 * `captures.toggle` opens or closes the popover; `captures.add` captures the
 * app's own current selection (a transcript, a diff, a file) and, with
 * nothing selected, opens the popover with the input focused. Both are
 * chat-route shortcuts, handled beside `composer.stash`.
 */
export function useCapturesShortcuts(input: {
  readonly keybindings: ResolvedKeybindingsConfig;
  readonly terminalOpen: boolean;
  readonly modelPickerOpen: boolean;
  readonly project: ActiveProjectRef | null;
}): void {
  const { keybindings, terminalOpen, modelPickerOpen, project } = input;
  const addCapture = useAddCapture();

  useEffect(() => {
    const handler = (event: globalThis.KeyboardEvent) => {
      const command = resolveShortcutCommand(event, keybindings, {
        context: {
          terminalFocus: getTerminalFocusOwner() !== null,
          terminalOpen,
          modelPickerOpen,
        },
      });
      if (command !== "captures.toggle" && command !== "captures.add") return;
      event.preventDefault();
      event.stopPropagation();
      if (isCommandPaletteOpen()) return;
      const ui = useCapturesUiStore.getState();
      if (command === "captures.toggle") {
        ui.toggle();
        return;
      }
      const selection = selectedText();
      if (selection === null || project === null) {
        ui.show({ focusInput: true });
        return;
      }
      void addCapture(selection, project);
    };
    window.addEventListener("keydown", handler, true);
    return () => window.removeEventListener("keydown", handler, true);
  }, [addCapture, keybindings, modelPickerOpen, project, terminalOpen]);
}
