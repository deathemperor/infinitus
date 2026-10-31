import { useEffect } from "react";
import { useCanGoBack, useNavigate } from "@tanstack/react-router";

import {
  mouseHistoryIntent,
  swipeHistoryIntent,
  type MouseHistoryIntent,
} from "../lib/backNavigation";

/**
 * Fork (#840, #1250): a mouse's back button (Chromium `button` 3) goes back on pages whose header
 * shows the back arrow; forward (4) goes forward anywhere. A driver mapping those buttons to
 * macOS's navigation gesture (Logi Options+) sends no mouse event, so the shell forwards it over
 * `onHistoryGesture` and the same rule runs. Mounted once, by the sidebar layout.
 */
export function useHistoryNavigation(pathname: string): void {
  const navigate = useNavigate();
  const canGoBack = useCanGoBack();
  // oxlint-disable-next-line t3code/no-unreasoned-state-sync -- window mouseup listener and desktop-bridge swipe gesture subscription for back and forward
  useEffect(() => {
    const applyHistoryIntent = (intent: MouseHistoryIntent) => {
      if (intent === "forward") {
        window.history.forward();
        return;
      }
      if (canGoBack) {
        window.history.back();
        return;
      }
      void navigate({ to: "/" });
    };
    const onMouseUp = (event: MouseEvent) => {
      const intent = mouseHistoryIntent(event.button, pathname);
      if (intent === null) return;
      event.preventDefault();
      applyHistoryIntent(intent);
    };
    window.addEventListener("mouseup", onMouseUp);
    const bridge = window.desktopBridge;
    const unsubscribeGesture =
      typeof bridge?.onHistoryGesture === "function"
        ? bridge.onHistoryGesture((direction) => {
            const intent = swipeHistoryIntent(direction, pathname);
            if (intent !== null) applyHistoryIntent(intent);
          })
        : undefined;
    return () => {
      window.removeEventListener("mouseup", onMouseUp);
      unsubscribeGesture?.();
    };
  }, [canGoBack, navigate, pathname]);
}
