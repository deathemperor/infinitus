/**
 * The capture gesture (#433 slice 2): with the knob on, a double tap of Shift
 * in any app reads that app's selected text and hands it to the renderer,
 * which adds it to the active project's captures. macOS only. The poller
 * starts with the knob and stops with it; one read runs at a time; the text
 * never reaches a log or a span, only its length. Turning the knob on asks
 * for the Accessibility grant (the same one SnapShot's context uses); a
 * launch with the knob already on checks it silently.
 *
 * Slice 3: the renderer pulls. A read is queued here and the page pinged;
 * the coordinator drains the queue on mount and on every ping, so a read
 * that lands while a fresh window is still loading — or after its load but
 * before the coordinator mounts — waits here instead of being sent to a
 * page with nobody listening.
 */
import type { DesktopCaptureGestureEvent } from "@t3tools/contracts";
import type { InfinitusDesktopPrefs } from "@t3tools/contracts/infinitus";
import * as Context from "effect/Context";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import * as Option from "effect/Option";
import * as Electron from "electron";

import * as DesktopEnvironment from "../app/DesktopEnvironment.ts";
import { makeComponentLogger } from "../app/DesktopObservability.ts";
import * as ElectronWindow from "../electron/ElectronWindow.ts";
import { CAPTURE_GESTURE_PENDING_CHANNEL } from "../ipc/channels.ts";
import {
  InfinitusDesktopPrefsService,
  type InfinitusDesktopPrefsWriteError,
} from "../infinitus/InfinitusDesktopPrefs.ts";
import * as DesktopWindow from "../window/DesktopWindow.ts";
import { startMacDoubleTapShiftProcess } from "./MacDoubleTapShiftProcess.ts";
import { readMacSelectedText } from "./MacSelectedText.ts";

export type CaptureGestureDeps = {
  readonly startPoller: (
    onTrigger: () => void,
    onFailure: (error: Error) => void,
  ) => Promise<() => void>;
  readonly readSelectedText: () => Promise<DesktopCaptureGestureEvent>;
  readonly dispatch: (event: DesktopCaptureGestureEvent) => Promise<void>;
  /** The Accessibility grant, asked for with the system prompt when `prompt`. */
  readonly accessibilityGranted: (prompt: boolean) => boolean;
  /** Heard in the app the user is in: the read got text. */
  readonly confirm: () => void;
  readonly log: (message: string, data?: Record<string, string | number>) => void;
};

export type CaptureGestureOutbox = {
  /** Queues the read; pings the page unless it is still loading (it pulls on mount). */
  readonly offer: (
    event: DesktopCaptureGestureEvent,
    page: { readonly loading: boolean; readonly ping: () => void },
  ) => void;
  /** The reads not yet pulled, oldest first; empties the queue. */
  readonly drain: () => ReadonlyArray<DesktopCaptureGestureEvent>;
};

export function makeCaptureGestureOutbox(): CaptureGestureOutbox {
  let pending: DesktopCaptureGestureEvent[] = [];
  return {
    offer: (event, page) => {
      pending.push(event);
      if (!page.loading) page.ping();
    },
    drain: () => {
      const drained = pending;
      pending = [];
      return drained;
    },
  };
}

export type CaptureGesture = {
  readonly setEnabled: (enabled: boolean, options?: { readonly prompt?: boolean }) => Promise<void>;
  readonly stop: () => void;
};

export function makeCaptureGesture(deps: CaptureGestureDeps): CaptureGesture {
  let wanted = false;
  let stopPoller: (() => void) | undefined;
  let starting: Promise<void> | undefined;
  let reading = false;

  const onTrigger = () => {
    if (reading) return;
    reading = true;
    void deps
      .readSelectedText()
      .catch((): DesktopCaptureGestureEvent => ({ type: "failed", reason: "helper" }))
      .then(async (event) => {
        if (event.type === "captured") deps.confirm();
        deps.log("gesture", {
          outcome: event.type,
          ...(event.type === "captured" ? { length: event.text.length } : {}),
          ...(event.type === "failed" ? { reason: event.reason } : {}),
        });
        await deps.dispatch(event).catch(() => undefined);
      })
      .finally(() => {
        reading = false;
      });
  };
  const stop = () => {
    stopPoller?.();
    stopPoller = undefined;
  };
  const start = async () => {
    if (stopPoller !== undefined || starting !== undefined) return;
    starting = deps
      .startPoller(onTrigger, (error) => {
        stopPoller = undefined;
        deps.log("poller failed", { error: error.message });
      })
      .then(
        (stopStarted) => {
          stopPoller = stopStarted;
          // Turned off again while it was coming up.
          if (!wanted) stop();
        },
        (error: unknown) => {
          deps.log("poller did not start", {
            error: error instanceof Error ? error.message : String(error),
          });
        },
      )
      .finally(() => {
        starting = undefined;
      });
    await starting;
  };

  return {
    setEnabled: async (enabled, options) => {
      wanted = enabled;
      if (!enabled) {
        stop();
        return;
      }
      if (!deps.accessibilityGranted(options?.prompt === true)) {
        deps.log("accessibility not granted");
      }
      await start();
    },
    stop,
  };
}

export class InfinitusCaptureGestureService extends Context.Service<
  InfinitusCaptureGestureService,
  {
    /** Writes the knob, then starts or stops the poller (macOS only). */
    readonly setEnabled: (
      enabled: boolean,
    ) => Effect.Effect<InfinitusDesktopPrefs, InfinitusDesktopPrefsWriteError>;
    /** The reads the renderer has not pulled yet, oldest first; empties the queue. */
    readonly consumePending: Effect.Effect<ReadonlyArray<DesktopCaptureGestureEvent>>;
  }
>()("@t3tools/desktop/captures/InfinitusCaptureGesture/InfinitusCaptureGestureService") {}

const { logInfo } = makeComponentLogger("infinitus-capture-gesture");

const make = Effect.gen(function* () {
  const environment = yield* DesktopEnvironment.DesktopEnvironment;
  const prefs = yield* InfinitusDesktopPrefsService;
  const desktopWindow = yield* DesktopWindow.DesktopWindow;
  const electronWindow = yield* ElectronWindow.ElectronWindow;
  const context = yield* Effect.context<never>();
  const runPromise = Effect.runPromiseWith(context);
  const supported = environment.platform === "darwin";
  const outbox = makeCaptureGestureOutbox();

  // The user is in another app: an open window is pinged without being
  // revealed; with none open, one is revealed so the text is not lost.
  const dispatch = Effect.fn("infinitus.captureGesture.dispatch")(function* (
    event: DesktopCaptureGestureEvent,
  ) {
    yield* Effect.annotateCurrentSpan({ event: event.type });
    const open = yield* electronWindow.main;
    const target = Option.isSome(open) ? open.value : yield* desktopWindow.revealOrCreateMain;
    if (target.isDestroyed()) return;
    outbox.offer(event, {
      loading: target.webContents.isLoadingMainFrame(),
      ping: () => target.webContents.send(CAPTURE_GESTURE_PENDING_CHANNEL),
    });
  });

  const gesture = makeCaptureGesture({
    startPoller: startMacDoubleTapShiftProcess,
    readSelectedText: readMacSelectedText,
    dispatch: (event) => runPromise(dispatch(event).pipe(Effect.ignoreCause)),
    accessibilityGranted: (prompt) =>
      Electron.systemPreferences.isTrustedAccessibilityClient(prompt),
    confirm: () => Electron.shell.beep(),
    log: (message, data) => void runPromise(logInfo(message, data)),
  });
  yield* Effect.addFinalizer(() => Effect.sync(gesture.stop));

  const initial = yield* prefs.get;
  if (supported && initial.captureGestureEnabled) {
    // Not awaited: the shell's startup does not wait on the poller's ready.
    void gesture.setEnabled(true, { prompt: false });
  }

  return InfinitusCaptureGestureService.of({
    setEnabled: Effect.fn("infinitus.captureGesture.setEnabled")(function* (enabled) {
      yield* Effect.annotateCurrentSpan({ enabled });
      const next = yield* prefs.setCaptureGestureEnabled(enabled);
      if (supported) yield* Effect.promise(() => gesture.setEnabled(enabled, { prompt: true }));
      return next;
    }),
    consumePending: Effect.sync(outbox.drain),
  });
});

export const layer = Layer.effect(InfinitusCaptureGestureService, make);
