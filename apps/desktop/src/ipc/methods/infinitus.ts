import { DesktopCaptureGestureEvent, DesktopDeepLink } from "@infinitus/contracts";
import {
  InfinitusDesktopPrefs,
  InfinitusEngineControlInput,
  InfinitusEngineSettingsInput,
  InfinitusEngines,
  InfinitusOAuthSignInInput,
  InfinitusOAuthSignInResult,
  InfinitusSignInCodeInput,
  InfinitusSignInCodeResult,
  InfinitusSignInRedirectListenInput,
  InfinitusSignInRedirectResult,
  InfinitusSignInWindowInput,
} from "@infinitus/contracts/infinitus";
import * as Effect from "effect/Effect";
import * as Schema from "effect/Schema";

import { InfinitusCaptureGestureService } from "../../captures/InfinitusCaptureGesture.ts";
import { InfinitusDeepLinksService } from "../../infinitus/InfinitusDeepLinks.ts";
import { InfinitusDesktopPrefsService } from "../../infinitus/InfinitusDesktopPrefs.ts";
import { InfinitusEngineSupervisorService } from "../../infinitus/InfinitusEngineSupervisor.ts";
import { InfinitusKeepAwakeService } from "../../infinitus/InfinitusKeepAwake.ts";
import { InfinitusOAuthSignInService } from "../../infinitus/InfinitusOAuthSignIn.ts";
import { InfinitusSignInService } from "../../infinitus/InfinitusSignIn.ts";
import { InfinitusSignInRedirectService } from "../../infinitus/InfinitusSignInRedirect.ts";
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

export const beginInfinitusOAuthSignIn = makeIpcMethod({
  channel: IpcChannels.BEGIN_INFINITUS_OAUTH_SIGN_IN_CHANNEL,
  payload: InfinitusOAuthSignInInput,
  result: InfinitusOAuthSignInResult,
  handler: Effect.fn("desktop.ipc.infinitus.beginOAuthSignIn")(function* (input) {
    const signIn = yield* InfinitusOAuthSignInService;
    return yield* signIn.begin(input);
  }),
});

export const cancelInfinitusOAuthSignIn = makeIpcMethod({
  channel: IpcChannels.CANCEL_INFINITUS_OAUTH_SIGN_IN_CHANNEL,
  payload: Schema.String,
  result: Schema.Void,
  handler: Effect.fn("desktop.ipc.infinitus.cancelOAuthSignIn")(function* (flowId) {
    const signIn = yield* InfinitusOAuthSignInService;
    yield* signIn.cancel(flowId);
  }),
});

export const listenInfinitusSignInRedirect = makeIpcMethod({
  channel: IpcChannels.LISTEN_INFINITUS_SIGN_IN_REDIRECT_CHANNEL,
  payload: InfinitusSignInRedirectListenInput,
  result: InfinitusSignInRedirectResult,
  handler: Effect.fn("desktop.ipc.infinitus.listenSignInRedirect")(function* (input) {
    const redirect = yield* InfinitusSignInRedirectService;
    return yield* redirect.listen(input);
  }),
});

export const stopInfinitusSignInRedirect = makeIpcMethod({
  channel: IpcChannels.STOP_INFINITUS_SIGN_IN_REDIRECT_CHANNEL,
  payload: Schema.String,
  result: Schema.Void,
  handler: Effect.fn("desktop.ipc.infinitus.stopSignInRedirect")(function* (flowId) {
    const redirect = yield* InfinitusSignInRedirectService;
    yield* redirect.stop(flowId);
  }),
});

export const consumePendingCaptureGestures = makeIpcMethod({
  channel: IpcChannels.CONSUME_CAPTURE_GESTURES_CHANNEL,
  payload: Schema.Void,
  result: Schema.Array(DesktopCaptureGestureEvent),
  handler: Effect.fn("desktop.ipc.infinitus.consumePendingCaptureGestures")(function* () {
    const gesture = yield* InfinitusCaptureGestureService;
    return yield* gesture.consumePending;
  }),
});

export const consumeInfinitusDeepLink = makeIpcMethod({
  channel: IpcChannels.CONSUME_INFINITUS_DEEP_LINK_CHANNEL,
  payload: Schema.Void,
  result: Schema.NullOr(DesktopDeepLink),
  handler: Effect.fn("desktop.ipc.infinitus.consumeDeepLink")(function* () {
    const deepLinks = yield* InfinitusDeepLinksService;
    return yield* deepLinks.consume;
  }),
});

export const setKeepAwake = makeIpcMethod({
  channel: IpcChannels.SET_KEEP_AWAKE_CHANNEL,
  payload: Schema.Boolean,
  result: Schema.Void,
  handler: Effect.fn("desktop.ipc.infinitus.setKeepAwake")(function* (active) {
    const keepAwake = yield* InfinitusKeepAwakeService;
    yield* keepAwake.set(active);
  }),
});

export const getInfinitusEngines = makeIpcMethod({
  channel: IpcChannels.GET_INFINITUS_ENGINES_CHANNEL,
  payload: Schema.Void,
  result: InfinitusEngines,
  handler: Effect.fn("desktop.ipc.infinitus.getEngines")(function* () {
    const engines = yield* InfinitusEngineSupervisorService;
    return yield* engines.get;
  }),
});

export const setInfinitusEngineSettings = makeIpcMethod({
  channel: IpcChannels.SET_INFINITUS_ENGINE_SETTINGS_CHANNEL,
  payload: InfinitusEngineSettingsInput,
  result: InfinitusEngines,
  handler: Effect.fn("desktop.ipc.infinitus.setEngineSettings")(function* (input) {
    const engines = yield* InfinitusEngineSupervisorService;
    return yield* engines.setSettings(input);
  }),
});

export const controlInfinitusEngine = makeIpcMethod({
  channel: IpcChannels.CONTROL_INFINITUS_ENGINE_CHANNEL,
  payload: InfinitusEngineControlInput,
  result: InfinitusEngines,
  handler: Effect.fn("desktop.ipc.infinitus.controlEngine")(function* (input) {
    const engines = yield* InfinitusEngineSupervisorService;
    return yield* engines.control(input);
  }),
});
