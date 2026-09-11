import { assert, describe, it } from "@effect/vitest";
import * as Effect from "effect/Effect";
import { beforeEach, vi } from "vite-plus/test";

import * as ElectronNotification from "./ElectronNotification.ts";

const { isSupportedMock, setBadgeCountMock, notifications } = vi.hoisted(() => ({
  isSupportedMock: vi.fn(),
  setBadgeCountMock: vi.fn(),
  notifications: [] as Array<{
    options: { title: string; body: string };
    listeners: Map<string, () => void>;
    shown: number;
  }>,
}));

vi.mock("electron", () => {
  class Notification {
    static isSupported = isSupportedMock;
    readonly record: (typeof notifications)[number];
    constructor(options: { title: string; body: string }) {
      this.record = { options, listeners: new Map(), shown: 0 };
      notifications.push(this.record);
    }
    on(event: string, listener: () => void) {
      this.record.listeners.set(event, listener);
      return this;
    }
    show() {
      this.record.shown += 1;
    }
  }
  return { Notification, app: { setBadgeCount: setBadgeCountMock } };
});

describe("ElectronNotification", () => {
  beforeEach(() => {
    isSupportedMock.mockReset();
    setBadgeCountMock.mockReset();
    notifications.length = 0;
  });

  it.effect("shows a notification and hands its click to the caller", () =>
    Effect.gen(function* () {
      isSupportedMock.mockReturnValue(true);
      const clicks: string[] = [];
      const service = yield* ElectronNotification.ElectronNotification;
      yield* service.show({ title: "Thread a", body: "Waiting", onClick: () => clicks.push("a") });
      assert.strictEqual(notifications.length, 1);
      assert.deepStrictEqual(notifications[0]?.options, { title: "Thread a", body: "Waiting" });
      assert.strictEqual(notifications[0]?.shown, 1);
      notifications[0]?.listeners.get("click")?.();
      assert.deepStrictEqual(clicks, ["a"]);
    }).pipe(Effect.provide(ElectronNotification.layer)),
  );

  it.effect("shows nothing where notifications are unsupported", () =>
    Effect.gen(function* () {
      isSupportedMock.mockReturnValue(false);
      const service = yield* ElectronNotification.ElectronNotification;
      yield* service.show({ title: "Thread a", body: "Waiting", onClick: () => {} });
      assert.strictEqual(notifications.length, 0);
    }).pipe(Effect.provide(ElectronNotification.layer)),
  );

  it.effect("sets the badge count on the app", () =>
    Effect.gen(function* () {
      setBadgeCountMock.mockReturnValue(true);
      const service = yield* ElectronNotification.ElectronNotification;
      yield* service.setBadgeCount(3);
      assert.deepStrictEqual(setBadgeCountMock.mock.calls, [[3]]);
    }).pipe(Effect.provide(ElectronNotification.layer)),
  );
});
