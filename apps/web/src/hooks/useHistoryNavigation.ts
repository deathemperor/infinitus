import { useEffect } from "react";
import { useCanGoBack, useNavigate } from "@tanstack/react-router";

import {
  mouseHistoryIntent,
  swipeHistoryIntent,
  type MouseHistoryIntent,
} from "../lib/backNavigation";

/**
 * Fork (#840, #1250): a mouse's back button (Chromium `button` 3) goes back
 * on the pages whose header shows the back arrow; its forward button (4)
 * goes forward anywhere. Electron hands them to the renderer as plain mouse
 * events with no default action. A driver that maps those buttons to macOS's
 * navigation gesture instead (Logi Options+ does) never produces a mouse
 * event: the shell forwards the gesture over `onHistoryGesture` and the same
 * rule runs. Mounted once, by the app's sidebar layout.
 */
export function useHistoryNavigation(pathname: string): void {
  const navigate = useNavigate();
  const canGoBack = useCanGoBack();
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
