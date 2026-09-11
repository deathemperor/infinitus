import type { InfinitusManifestCommand, InfinitusSnapshot } from "@t3tools/contracts/infinitus";
import { it as effectIt } from "@effect/vitest";
import * as Context from "effect/Context";
import * as Duration from "effect/Duration";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import * as Redacted from "effect/Redacted";
import * as Ref from "effect/Ref";
import * as Stream from "effect/Stream";
import * as TestClock from "effect/testing/TestClock";
import { describe, expect } from "vite-plus/test";

import { InfinitusService } from "../Services/Infinitus.ts";
import {
  InfinitusControlClient,
  type InfinitusControlRequestInput,
} from "../Services/InfinitusControlClient.ts";
import { InfinitusSecret } from "../Services/InfinitusSecret.ts";
import { NOT_POLLED_REASON } from "./Infinitus.ts";
import { InfinitusSecretLive, SECRET_ATTEMPTS_PER_MINUTE } from "./InfinitusSecret.ts";

const command = (
  name: string,
  overrides: Partial<InfinitusManifestCommand> = {},
): InfinitusManifestCommand => ({
  name,
  args: [],
  options: [],
  effect: "write",
  summary: "",
  replyShape: "",
  ...overrides,
});

const manifest: ReadonlyArray<InfinitusManifestCommand> = [
  // Spelled the way native's manifest spells them (ControlProtocol.swift):
  // positionals in angle brackets, options as their usage line.
  command("signin-code", { args: ["<flowId>"], stdin: "secret" }),
  command("proxy-key", {
    options: ["--url <base URL, default http://127.0.0.1:8317>"],
    stdin: "secret",
  }),
  command("send", { args: ["<target>"], stdin: "payload" }),
  command("status", { effect: "read" }),
];

const snapshotWith = (commands: ReadonlyArray<InfinitusManifestCommand>): InfinitusSnapshot => ({
  available: true,
  fleets: [],
  sessions: [],
  commands,
});

const unavailable = (reason: string): InfinitusSnapshot => ({
  available: false,
  unavailableReason: reason,
  fleets: [],
  sessions: [],
  commands: [],
});
const notPolled = unavailable(NOT_POLLED_REASON);

const makeHarness = (initial: InfinitusSnapshot = snapshotWith(manifest)) =>
  Effect.gen(function* () {
    const current = yield* Ref.make(initial);
    const requests = yield* Ref.make<ReadonlyArray<InfinitusControlRequestInput>>([]);
    const refreshes = yield* Ref.make(0);
    const layer = InfinitusSecretLive.pipe(
      Layer.provide(
        Layer.mergeAll(
          Layer.mock(InfinitusService)({
            snapshot: Ref.get(current),
            // A refresh reads the manifest for real: here it lands the table.
            refresh: Ref.update(refreshes, (n) => n + 1).pipe(
              Effect.andThen(Ref.set(current, snapshotWith(manifest))),
            ),
            changes: () => Stream.empty,
            observed: Stream.empty,
          }),
          Layer.mock(InfinitusControlClient)({
            socketPath: "/tmp/test.sock",
            request: (input) =>
              Ref.update(requests, (list) => [...list, input]).pipe(
                Effect.as({ ok: true, state: "signed-in" }),
              ),
          }),
        ),
      ),
    );
    const context = yield* Layer.build(layer);
    const secret = Context.get(context, InfinitusSecret);
    return {
      forward: (
        input: Partial<Parameters<typeof secret.forward>[0]> & { readonly command: string },
      ) =>
        secret.forward({
          sessionId: "session-1",
          args: {},
          secret: Redacted.make("s3cret"),
          ...input,
        }),
      requests: Ref.get(requests),
      refreshes: Ref.get(refreshes),
    };
  });

describe("InfinitusSecretLive", () => {
  effectIt.effect(
    "forwards the secret on the request line to a verb the manifest says takes one",
    () =>
      Effect.scoped(
        Effect.gen(function* () {
          const h = yield* makeHarness();
          const result = yield* h.forward({ command: "signin-code", args: { flowId: "flow-7" } });
          expect(result).toEqual({ result: { ok: true, state: "signed-in" } });
          expect(yield* h.requests).toEqual([
            { command: "signin-code", args: ["flow-7"], options: {}, secret: "s3cret" },
          ]);
        }),
      ),
  );

  effectIt.effect("maps an option by its bare manifest name", () =>
    Effect.scoped(
      Effect.gen(function* () {
        const h = yield* makeHarness();
        yield* h.forward({ command: "proxy-key", args: { url: "http://127.0.0.1:8317" } });
        expect(yield* h.requests).toEqual([
          {
            command: "proxy-key",
            args: [],
            options: { url: "http://127.0.0.1:8317" },
            secret: "s3cret",
          },
        ]);
      }),
    ),
  );

  effectIt.effect(
    "refuses a verb whose manifest entry does not say secret, before the socket",
    () =>
      Effect.scoped(
        Effect.gen(function* () {
          const h = yield* makeHarness();
          const payload = yield* h
            .forward({ command: "send", args: { target: "1" } })
            .pipe(Effect.flip);
          expect(payload).toMatchObject({ _tag: "InfinitusSecretRefused", reason: "no_secret" });
          const plain = yield* h.forward({ command: "status" }).pipe(Effect.flip);
          expect(plain).toMatchObject({ _tag: "InfinitusSecretRefused", reason: "no_secret" });
          const unknown = yield* h.forward({ command: "nope" }).pipe(Effect.flip);
          expect(unknown).toMatchObject({ _tag: "InfinitusSecretRefused", reason: "no_secret" });
          expect(yield* h.requests).toEqual([]);
        }),
      ),
  );

  effectIt.effect("refuses an argument the verb does not name, and a missing positional", () =>
    Effect.scoped(
      Effect.gen(function* () {
        const h = yield* makeHarness();
        const extra = yield* h
          .forward({ command: "signin-code", args: { flowId: "f", other: "x" } })
          .pipe(Effect.flip);
        expect(extra).toMatchObject({ reason: "bad_args", detail: "other" });
        const missing = yield* h.forward({ command: "signin-code" }).pipe(Effect.flip);
        expect(missing).toMatchObject({ reason: "bad_args", detail: "flowId" });
        expect(yield* h.requests).toEqual([]);
      }),
    ),
  );

  effectIt.effect("reads the manifest once on a server nobody polls, and refuses without one", () =>
    Effect.scoped(
      Effect.gen(function* () {
        const h = yield* makeHarness(notPolled);
        yield* h.forward({ command: "signin-code", args: { flowId: "f" } });
        expect((yield* h.requests).length).toBe(1);
        // One read for the manifest before the call, one after the write.
        expect(yield* h.refreshes).toBe(2);

        const empty = yield* makeHarness(snapshotWith([]));
        const refused = yield* empty.forward({ command: "signin-code" }).pipe(Effect.flip);
        expect(refused).toMatchObject({ reason: "no_manifest" });
        expect(yield* empty.refreshes).toBe(0);
      }),
    ),
  );

  effectIt.effect("says the app is unreachable the way every other path does", () =>
    Effect.scoped(
      Effect.gen(function* () {
        const h = yield* makeHarness(unavailable("connect ENOENT /tmp/test.sock"));
        const failed = yield* h.forward({ command: "signin-code" }).pipe(Effect.flip);
        expect(failed).toMatchObject({
          _tag: "InfinitusUnavailable",
          path: "/tmp/test.sock",
          cause: "connect ENOENT /tmp/test.sock",
        });
        expect(yield* h.requests).toEqual([]);
      }),
    ),
  );

  effectIt.effect(
    "refuses a session's sixth attempt at a verb within a minute, and allows it after",
    () =>
      Effect.scoped(
        Effect.gen(function* () {
          const h = yield* makeHarness();
          for (let i = 0; i < SECRET_ATTEMPTS_PER_MINUTE; i += 1) {
            yield* h.forward({ command: "signin-code", args: { flowId: "f" } });
          }
          const refused = yield* h
            .forward({ command: "signin-code", args: { flowId: "f" } })
            .pipe(Effect.flip);
          expect(refused).toMatchObject({ reason: "too_many_attempts" });
          // Another session, another verb: their own counters.
          yield* h.forward({
            command: "signin-code",
            args: { flowId: "f" },
            sessionId: "session-2",
          });
          yield* h.forward({ command: "proxy-key", args: { url: "http://x" } });

          yield* TestClock.adjust(Duration.seconds(61));
          yield* h.forward({ command: "signin-code", args: { flowId: "f" } });
          expect((yield* h.requests).length).toBe(SECRET_ATTEMPTS_PER_MINUTE + 3);
        }),
      ),
  );
});
