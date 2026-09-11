import { DesktopNotificationRequest } from "@t3tools/contracts";
import * as Effect from "effect/Effect";
import * as Schema from "effect/Schema";

import * as ElectronNotification from "../../electron/ElectronNotification.ts";
import * as DesktopWindow from "../../window/DesktopWindow.ts";
import * as IpcChannels from "../channels.ts";
import { makeIpcMethod } from "../DesktopIpc.ts";

/**
 * Fork (#270 B): the renderer decides what earns a notification; the main
 * process only shows it and, on a click, reveals the window on the thread.
 */
export const postNotification = makeIpcMethod({
  channel: IpcChannels.POST_NOTIFICATION_CHANNEL,
  payload: DesktopNotificationRequest,
  result: Schema.Void,
  handler: Effect.fn("desktop.ipc.notifications.post")(function* (input) {
    const notification = yield* ElectronNotification.ElectronNotification;
    const window = yield* DesktopWindow.DesktopWindow;
    const context = yield* Effect.context<DesktopWindow.DesktopWindow>();
    const runFork = Effect.runForkWith(context);
    yield* notification.show({
      title: input.title,
      body: input.body,
      onClick: () =>
        void runFork(
          window
            .dispatchNotificationActivated({
              environmentId: input.environmentId,
              threadId: input.threadId,
            })
            .pipe(Effect.ignoreCause),
        ),
    });
  }),
});

export const setBadgeCount = makeIpcMethod({
  channel: IpcChannels.SET_BADGE_COUNT_CHANNEL,
  payload: Schema.Number,
  result: Schema.Void,
  handler: Effect.fn("desktop.ipc.notifications.setBadgeCount")(function* (count) {
    const notification = yield* ElectronNotification.ElectronNotification;
    yield* notification.setBadgeCount(count);
  }),
});
