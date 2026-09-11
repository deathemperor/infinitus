import { InfinitusCommandFailed, InfinitusUnavailable } from "@t3tools/contracts/infinitus";
import { it as effectIt } from "@effect/vitest";
import * as Effect from "effect/Effect";
import * as Ref from "effect/Ref";
import { describe, expect } from "vite-plus/test";

import { quitInfinitusIfListed } from "./InfinitusQuitWithApp.ts";

const manifest = (...names: ReadonlyArray<string>) => ({
  schemaVersion: 1,
  commands: names.map((name) => ({
    name,
    args: [],
    options: [],
    effect: "read",
    summary: name,
    replyShape: "{}",
  })),
});

const stub =
  (calls: Ref.Ref<ReadonlyArray<string>>, replies: Record<string, unknown>) =>
  (input: { readonly command: string }) =>
    Ref.update(calls, (previous) => [...previous, input.command]).pipe(
      Effect.andThen(
        Object.hasOwn(replies, input.command)
          ? Effect.succeed(replies[input.command])
          : Effect.fail(
              new InfinitusCommandFailed({
                command: input.command,
                error: "unknown command",
                restarting: false,
              }),
            ),
      ),
    );

describe("quitInfinitusIfListed", () => {
  effectIt.effect("sends quit only after the manifest lists it", () =>
    Effect.gen(function* () {
      const calls = yield* Ref.make<ReadonlyArray<string>>([]);
      const outcome = yield* quitInfinitusIfListed(
        stub(calls, { manifest: manifest("status", "quit"), quit: undefined }),
      );
      expect(outcome).toBe("sent");
      expect(yield* Ref.get(calls)).toEqual(["manifest", "quit"]);
    }),
  );

  effectIt.effect("leaves an app without the verb alone", () =>
    Effect.gen(function* () {
      const calls = yield* Ref.make<ReadonlyArray<string>>([]);
      const outcome = yield* quitInfinitusIfListed(stub(calls, { manifest: manifest("status") }));
      expect(outcome).toBe("no-quit-verb");
      expect(yield* Ref.get(calls)).toEqual(["manifest"]);
    }),
  );

  effectIt.effect("answers unavailable for a dead socket and failed for a refused quit", () =>
    Effect.gen(function* () {
      const calls = yield* Ref.make<ReadonlyArray<string>>([]);
      const dead = yield* quitInfinitusIfListed(() =>
        Effect.fail(new InfinitusUnavailable({ path: "/tmp/x.sock", cause: "ENOENT" })),
      );
      expect(dead).toBe("unavailable");
      const refused = yield* quitInfinitusIfListed(stub(calls, { manifest: manifest("quit") }));
      expect(refused).toBe("failed");
    }),
  );
});
