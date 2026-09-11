import * as Context from "effect/Context";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";

import * as Electron from "electron";

export interface ElectronNotificationShowInput {
  readonly title: string;
  readonly body: string;
  /** The user clicked the banner or the Notification Center entry. */
  readonly onClick: () => void;
}

/**
 * Fork (#270 B): the OS notification and the Dock badge, main-process only.
 * `show` is a no-op where the platform has no notification centre; a click
 * calls back synchronously, and the caller decides what an activation does.
 */
export class ElectronNotification extends Context.Service<
  ElectronNotification,
  {
    readonly show: (input: ElectronNotificationShowInput) => Effect.Effect<void>;
    readonly setBadgeCount: (count: number) => Effect.Effect<void>;
  }
>()("@t3tools/desktop/electron/ElectronNotification") {}

/** @public Service construction is part of the canonical Effect module API. */
export const make = ElectronNotification.of({
  show: (input) =>
    Effect.sync(() => {
      if (!Electron.Notification.isSupported()) return;
      const notification = new Electron.Notification({ title: input.title, body: input.body });
      notification.on("click", () => input.onClick());
      notification.show();
    }),
  setBadgeCount: (count) =>
    Effect.sync(() => {
      Electron.app.setBadgeCount(count);
    }),
});

export const layer = Layer.succeed(ElectronNotification, make);
