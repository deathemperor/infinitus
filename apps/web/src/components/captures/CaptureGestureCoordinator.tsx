import { useCallback, useEffect, useRef } from "react";

import { toastManager } from "../ui/toast";
import { captureGestureFailureMessage, resolveCaptureGestureProject } from "./captureGesture.logic";
import { captureSnippet } from "./captures.logic";
import { type ActiveProjectRef, useActiveProjectRef, useAddCapture } from "./useCaptures";

/**
 * Mounted once in the app shell: the desktop's double-tap-Shift gesture
 * (#433 slice 2) as captures. The text goes to the routed thread's project,
 * else to the last project a gesture reached, else it is held until a
 * thread with a project is open — never dropped. Nothing here reveals the
 * window; the shell's beep is the confirmation, the toasts wait for the
 * user to come back.
 */
export function CaptureGestureCoordinator() {
  const project = useActiveProjectRef();
  const addCapture = useAddCapture();
  const lastProjectRef = useRef<ActiveProjectRef | null>(null);
  const pendingRef = useRef<string | null>(null);

  const deliver = useCallback(
    async (text: string) => {
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
    },
    [addCapture, project],
  );
  const deliverRef = useRef(deliver);
  useEffect(() => {
    deliverRef.current = deliver;
  }, [deliver]);

  useEffect(() => {
    if (project !== null) lastProjectRef.current = project;
    const pending = pendingRef.current;
    if (pending === null || project === null) return;
    pendingRef.current = null;
    void deliver(pending);
  }, [deliver, project]);

  useEffect(() => {
    const bridge = typeof window === "undefined" ? undefined : window.desktopBridge;
    if (typeof bridge?.onCaptureGestureEvent !== "function") return;
    return bridge.onCaptureGestureEvent((event) => {
      if (event.type === "captured") {
        void deliverRef.current(event.text);
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
    });
  }, []);

  return null;
}
