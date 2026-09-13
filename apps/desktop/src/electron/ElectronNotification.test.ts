import { assert, describe, it } from "@effect/vitest";
import * as Effect from "effect/Effect";
import { beforeEach, vi } from "vite-plus/test";

import * as ElectronNotification from "./ElectronNotification.ts";

const { setBadgeCountMock } = vi.hoisted(() => ({ setBadgeCountMock: vi.fn() }));

vi.mock("electron", () => ({ app: { setBadgeCount: setBadgeCountMock } }));

describe("ElectronNotification", () => {
  beforeEach(() => {
    setBadgeCountMock.mockReset();
  });

  it.effect("sets the badge count on the app", () =>
    Effect.gen(function* () {
      setBadgeCountMock.mockReturnValue(true);
      const service = yield* ElectronNotification.ElectronNotification;
      yield* service.setBadgeCount(3);
      assert.deepStrictEqual(setBadgeCountMock.mock.calls, [[3]]);
    }).pipe(Effect.provide(ElectronNotification.layer)),
  );
});
