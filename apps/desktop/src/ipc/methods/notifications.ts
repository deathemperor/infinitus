import * as Effect from "effect/Effect";
import * as Schema from "effect/Schema";

import * as ElectronNotification from "../../electron/ElectronNotification.ts";
import * as IpcChannels from "../channels.ts";
import { makeIpcMethod } from "../DesktopIpc.ts";

/** Fork (#270 B): the renderer counts the threads waiting on the user; the main process badges the Dock. */
export const setBadgeCount = makeIpcMethod({
  channel: IpcChannels.SET_BADGE_COUNT_CHANNEL,
  payload: Schema.Number,
  result: Schema.Void,
  handler: Effect.fn("desktop.ipc.notifications.setBadgeCount")(function* (count) {
    const notification = yield* ElectronNotification.ElectronNotification;
    yield* notification.setBadgeCount(count);
  }),
});
