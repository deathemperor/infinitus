import type { ExecutionEnvironmentDescriptor } from "@t3tools/contracts";
import type { InfinitusSnapshot } from "@t3tools/contracts/infinitus";
import { it as effectIt } from "@effect/vitest";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import * as Ref from "effect/Ref";
import * as Stream from "effect/Stream";
import { describe, expect, it } from "vite-plus/test";

import { InfinitusService } from "../Services/Infinitus.ts";
import { NOT_POLLED_REASON } from "./Infinitus.ts";
import { alternateHttpBaseUrls, withAlternateHttpBaseUrls } from "./InfinitusDescriptor.ts";

const descriptor = {
  environmentId: "env-1",
  label: "Mac",
  platform: { os: "darwin", arch: "arm64" },
  serverVersion: "0.0.0-test",
  capabilities: {},
} as unknown as ExecutionEnvironmentDescriptor;

const status = (forkTunnel: Record<string, unknown> | undefined) =>
  ({
    version: "1",
    sha: "abc",
    socket: "/tmp/x.sock",
    badge: "",
    playground: false,
    signInRunning: false,
    engines: {},
    ...(forkTunnel === undefined ? {} : { forkTunnel }),
  }) as unknown as NonNullable<InfinitusSnapshot["status"]>;

const polled = (forkTunnel: Record<string, unknown> | undefined): InfinitusSnapshot => ({
  available: true,
  status: status(forkTunnel),
  fleets: [],
  sessions: [],
  commands: [],
});

const notPolled: InfinitusSnapshot = {
  available: false,
  unavailableReason: NOT_POLLED_REASON,
  fleets: [],
  sessions: [],
  commands: [],
};

const tunnelUp = { enabled: true, port: 3773, state: "up", url: "https://code.infinitus.run" };

describe("alternateHttpBaseUrls", () => {
  it("is the tunnel's URL while it is up, nothing otherwise", () => {
    expect(alternateHttpBaseUrls(polled(tunnelUp))).toEqual(["https://code.infinitus.run"]);
    expect(alternateHttpBaseUrls(polled({ ...tunnelUp, state: "down" }))).toEqual([]);
    expect(alternateHttpBaseUrls(polled({ enabled: true, port: 3773, state: "up" }))).toEqual([]);
    expect(alternateHttpBaseUrls(polled(undefined))).toEqual([]);
    expect(alternateHttpBaseUrls(notPolled)).toEqual([]);
  });
});

describe("withAlternateHttpBaseUrls", () => {
  const harness = (first: InfinitusSnapshot, afterRefresh: InfinitusSnapshot) =>
    Effect.gen(function* () {
      const current = yield* Ref.make(first);
      const refreshes = yield* Ref.make(0);
      const layer = Layer.mock(InfinitusService)({
        snapshot: Ref.get(current),
        refresh: Ref.update(refreshes, (n) => n + 1).pipe(
          Effect.andThen(Ref.set(current, afterRefresh)),
        ),
        changes: () => Stream.empty,
        observed: Stream.empty,
      });
      return { layer, refreshes: Ref.get(refreshes) };
    });

  effectIt.effect("polls once on a never-polled server, then names the tunnel", () =>
    Effect.gen(function* () {
      const h = yield* harness(notPolled, polled(tunnelUp));
      const result = yield* withAlternateHttpBaseUrls(descriptor).pipe(Effect.provide(h.layer));
      expect(result.alternateHttpBaseUrls).toEqual(["https://code.infinitus.run"]);
      expect(yield* h.refreshes).toBe(1);
    }),
  );

  effectIt.effect("reads a polled snapshot as is and leaves the field off with no tunnel", () =>
    Effect.gen(function* () {
      const h = yield* harness(polled(undefined), polled(tunnelUp));
      const result = yield* withAlternateHttpBaseUrls(descriptor).pipe(Effect.provide(h.layer));
      expect(result).toEqual(descriptor);
      expect("alternateHttpBaseUrls" in result).toBe(false);
      expect(yield* h.refreshes).toBe(0);
    }),
  );
});
