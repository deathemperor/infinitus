import * as Context from "effect/Context";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";

import * as Electron from "electron";

/** Fork (#270 B): the Dock badge, main-process only. Banners are the renderer's `Notification` (#1032). */
export class ElectronNotification extends Context.Service<
  ElectronNotification,
  {
    readonly setBadgeCount: (count: number) => Effect.Effect<void>;
  }
>()("@infinitus/desktop/electron/ElectronNotification") {}

/** @public */
export const make = ElectronNotification.of({
  setBadgeCount: Effect.fn("ElectronNotification.setBadgeCount")(function (count) {
    return Effect.sync(() => {
      Electron.app.setBadgeCount(count);
    });
  }),
});

export const layer = Layer.succeed(ElectronNotification, make);
