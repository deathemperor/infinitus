import {
  InfinitusDesktopPrefs,
  InfinitusSignInCodeInput,
  InfinitusSignInCodeResult,
  InfinitusSignInWindowInput,
} from "@t3tools/contracts/infinitus";
import * as Effect from "effect/Effect";
import * as Schema from "effect/Schema";

import { InfinitusCaptureGestureService } from "../../captures/InfinitusCaptureGesture.ts";
import { InfinitusDesktopPrefsService } from "../../infinitus/InfinitusDesktopPrefs.ts";
import { InfinitusSignInService } from "../../infinitus/InfinitusSignIn.ts";
import * as IpcChannels from "../channels.ts";
import { makeIpcMethod } from "../DesktopIpc.ts";

export const getInfinitusDesktopPrefs = makeIpcMethod({
  channel: IpcChannels.GET_INFINITUS_DESKTOP_PREFS_CHANNEL,
  payload: Schema.Void,
  result: InfinitusDesktopPrefs,
  handler: Effect.fn("desktop.ipc.infinitus.getDesktopPrefs")(function* () {
    const prefs = yield* InfinitusDesktopPrefsService;
    return yield* prefs.get;
  }),
});

export const setInfinitusQuitWithApp = makeIpcMethod({
  channel: IpcChannels.SET_INFINITUS_QUIT_WITH_APP_CHANNEL,
  payload: Schema.Boolean,
  result: InfinitusDesktopPrefs,
  handler: Effect.fn("desktop.ipc.infinitus.setQuitWithApp")(function* (enabled) {
    const prefs = yield* InfinitusDesktopPrefsService;
    return yield* prefs.setQuitWithApp(enabled);
  }),
});

export const setInfinitusCaptureGestureEnabled = makeIpcMethod({
  channel: IpcChannels.SET_INFINITUS_CAPTURE_GESTURE_ENABLED_CHANNEL,
  payload: Schema.Boolean,
  result: InfinitusDesktopPrefs,
  handler: Effect.fn("desktop.ipc.infinitus.setCaptureGestureEnabled")(function* (enabled) {
    const gesture = yield* InfinitusCaptureGestureService;
    return yield* gesture.setEnabled(enabled);
  }),
});

export const openInfinitusSignIn = makeIpcMethod({
  channel: IpcChannels.OPEN_INFINITUS_SIGN_IN_CHANNEL,
  payload: InfinitusSignInWindowInput,
  result: Schema.Void,
  handler: Effect.fn("desktop.ipc.infinitus.openSignIn")(function* (input) {
    const signIn = yield* InfinitusSignInService;
    yield* signIn.open(input);
  }),
});

export const closeInfinitusSignIn = makeIpcMethod({
  channel: IpcChannels.CLOSE_INFINITUS_SIGN_IN_CHANNEL,
  payload: Schema.String,
  result: Schema.Void,
  handler: Effect.fn("desktop.ipc.infinitus.closeSignIn")(function* (flowId) {
    const signIn = yield* InfinitusSignInService;
    yield* signIn.close(flowId);
  }),
});

export const submitInfinitusSignInCode = makeIpcMethod({
  channel: IpcChannels.SUBMIT_INFINITUS_SIGN_IN_CODE_CHANNEL,
  payload: InfinitusSignInCodeInput,
  result: InfinitusSignInCodeResult,
  handler: Effect.fn("desktop.ipc.infinitus.submitSignInCode")(function* (input) {
    const signIn = yield* InfinitusSignInService;
    return yield* signIn.submitCode(input);
  }),
});
