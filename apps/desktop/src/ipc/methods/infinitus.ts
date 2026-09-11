import { InfinitusDesktopPrefs } from "@t3tools/contracts/infinitus";
import * as Effect from "effect/Effect";
import * as Schema from "effect/Schema";

import { InfinitusDesktopPrefsService } from "../../infinitus/InfinitusDesktopPrefs.ts";
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
