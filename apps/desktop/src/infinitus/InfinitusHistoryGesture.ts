/**
 * macOS's navigate-back/forward gesture, forwarded to the renderer (#1250).
 * Logi Options+ maps a mouse's back and forward buttons to that gesture
 * (`OSX_GESTURE_BACK` / `_FORWARD`), not to Chromium buttons 3/4, so the
 * renderer's mouse listener (#841) never sees them; Chrome turns the gesture
 * into history navigation itself, Electron drops it unless a window listens.
 * This attaches `swipe` to every window as it is created and forwards the
 * direction from the main window only (a sign-in child has no preload); the
 * renderer applies the same backable-page rule as the mouse buttons. One log
 * line per gesture, direction only, is the device check: it says whether the
 * driver's gesture reached Electron at all.
 */
import * as Electron from "electron";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import * as Option from "effect/Option";

import * as DesktopEnvironment from "../app/DesktopEnvironment.ts";
import { makeComponentLogger } from "../app/DesktopObservability.ts";
import * as ElectronWindow from "../electron/ElectronWindow.ts";
import { INFINITUS_HISTORY_GESTURE_CHANNEL } from "../ipc/channels.ts";

const { logInfo } = makeComponentLogger("infinitus-history-gesture");

const make = Effect.gen(function* () {
  const environment = yield* DesktopEnvironment.DesktopEnvironment;
  if (environment.platform !== "darwin") return;
  const electronWindow = yield* ElectronWindow.ElectronWindow;
  const context = yield* Effect.context<never>();
  const runPromise = Effect.runPromiseWith(context);

  const forward = Effect.fn("infinitus.historyGesture.forward")(function* (
    window: Electron.BrowserWindow,
    direction: string,
  ) {
    if (direction !== "left" && direction !== "right") return;
    const main = yield* electronWindow.main;
    if (Option.isNone(main) || main.value !== window || window.isDestroyed()) return;
    yield* logInfo("infinitus.historyGesture", { direction });
    if (window.webContents.isLoadingMainFrame()) return;
    window.webContents.send(INFINITUS_HISTORY_GESTURE_CHANNEL, direction);
  });

  const attach = (window: Electron.BrowserWindow) => {
    window.on("swipe", (_event, direction) => {
      void runPromise(forward(window, direction).pipe(Effect.ignoreCause));
    });
  };
  const onCreated = (_event: Electron.Event, window: Electron.BrowserWindow) => attach(window);
  Electron.app.on("browser-window-created", onCreated);
  yield* Effect.addFinalizer(() =>
    Effect.sync(() => {
      Electron.app.removeListener("browser-window-created", onCreated);
    }),
  );
  // A main window that opened before this layer started gets its listener too.
  const open = yield* electronWindow.main;
  if (Option.isSome(open) && !open.value.isDestroyed()) attach(open.value);
});

export const layer = Layer.effectDiscard(make);
