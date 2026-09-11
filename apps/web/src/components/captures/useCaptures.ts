import { squashAtomCommandFailure } from "@t3tools/client-runtime/state/runtime";
import type { EnvironmentId, ProjectId, ResolvedKeybindingsConfig } from "@t3tools/contracts";
import { useCallback, useEffect } from "react";

import { isCommandPaletteOpen } from "../../commandPaletteBus";
import { useHandleNewThread } from "../../hooks/useHandleNewThread";
import { resolveShortcutCommand } from "../../keybindings";
import { getTerminalFocusOwner } from "../../lib/terminalFocus";
import { captures } from "../../state/captures";
import { useAtomCommand } from "../../state/use-atom-command";
import { toastManager } from "../ui/toast";
import { captureApplyFailureMessage, captureText } from "./captures.logic";
import { useCapturesUiStore } from "./capturesUiStore";

export interface ActiveProjectRef {
  readonly environmentId: EnvironmentId;
  readonly projectId: ProjectId;
}

/** The project the routed thread — or the draft, once a project is
    chosen — belongs to. Null on a draft with no project yet. */
export function useActiveProjectRef(): ActiveProjectRef | null {
  const { activeDraftThread, activeThread } = useHandleNewThread();
  const thread = activeThread ?? activeDraftThread;
  if (!thread) return null;
  return { environmentId: thread.environmentId, projectId: thread.projectId };
}

/** Adds one capture to the active project, toasting a refusal. */
function useAddCapture(project: ActiveProjectRef | null) {
  const apply = useAtomCommand(captures.apply, { reportFailure: false });
  return useCallback(
    async (raw: string): Promise<boolean> => {
      const text = captureText(raw);
      if (text === null || project === null) return false;
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
    [apply, project],
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
}): void {
  const { keybindings, terminalOpen, modelPickerOpen } = input;
  const project = useActiveProjectRef();
  const addCapture = useAddCapture(project);

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
      void addCapture(selection);
    };
    window.addEventListener("keydown", handler, true);
    return () => window.removeEventListener("keydown", handler, true);
  }, [addCapture, keybindings, modelPickerOpen, project, terminalOpen]);
}
