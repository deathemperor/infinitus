import type { DesktopCaptureGestureEvent } from "@infinitus/contracts";
import { useEffect, useRef } from "react";

import { useStableCallback } from "../../hooks/useStableCallback";
import { toastManager } from "../ui/toast";
import { captureGestureFailureMessage, resolveCaptureGestureProject } from "./captureGesture.logic";
import { captureSnippet } from "./captures.logic";
import { type ActiveProjectRef, useActiveProjectRef, useAddCapture } from "./useCaptures";

/**
 * Mounted once in the app shell: the desktop's double-tap-Shift gesture (#433) as captures. The
 * text goes to the routed thread's project, else the last project a gesture reached, else is held
 * until a thread with a project is open, never dropped. Pulls on mount and on every ping so a read
 * that beat the window's mount is still delivered.
 */
export function CaptureGestureCoordinator() {
  const project = useActiveProjectRef();
  const addCapture = useAddCapture();
  const lastProjectRef = useRef<ActiveProjectRef | null>(null);
  const pendingRef = useRef<string | null>(null);
  const queueRef = useRef(Promise.resolve());

  // One identity for the bridge subscription below; it always reads the
  // current project and command.
  const deliver = useStableCallback(async (text: string) => {
    const target = resolveCaptureGestureProject(project, lastProjectRef.current);
    if (target === null) {
      pendingRef.current = text;
      toastManager.add({
        type: "info",
        title: "Captured, waiting for a project",
        description: "Open a thread and the capture lands in its project.",
      });
      return;
    }
    lastProjectRef.current = target;
    if (await addCapture(text, target)) {
      toastManager.add({
        type: "success",
        title: "Captured",
        description: captureSnippet(text, 80),
      });
    }
  });

  // oxlint-disable-next-line t3code/no-unreasoned-state-sync -- delivers a desktop capture gesture that arrived before any project was open, once one is
  useEffect(() => {
    if (project !== null) lastProjectRef.current = project;
    const pending = pendingRef.current;
    if (pending === null || project === null) return;
    pendingRef.current = null;
    void deliver(pending);
  }, [deliver, project]);

  // oxlint-disable-next-line t3code/no-unreasoned-state-sync -- subscribes to the desktop bridge's capture gestures and drains the ones queued before mount
  useEffect(() => {
    const bridge = typeof window === "undefined" ? undefined : window.desktopBridge;
    if (
      typeof bridge?.consumePendingCaptureGestures !== "function" ||
      typeof bridge.onCaptureGesturePending !== "function"
    ) {
      return;
    }
    const consume = bridge.consumePendingCaptureGestures;
    const handle = async (event: DesktopCaptureGestureEvent) => {
      if (event.type === "captured") {
        await deliver(event.text);
        return;
      }
      if (event.type === "empty") {
        toastManager.add({
          type: "info",
          title: "Nothing selected",
          description: "Select text in the front app, then tap Shift twice.",
        });
        return;
      }
      toastManager.add({
        type: "error",
        title: "Capture failed",
        description: captureGestureFailureMessage(event.reason),
      });
    };
    const drain = () => {
      queueRef.current = queueRef.current
        .then(async () => {
          for (const event of await consume()) await handle(event);
        })
        .catch(() => undefined);
    };
    const unsubscribe = bridge.onCaptureGesturePending(drain);
    drain();
    return unsubscribe;
  }, [deliver]);

  return null;
}
