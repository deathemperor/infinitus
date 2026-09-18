import { it } from "@effect/vitest";
import { expect } from "vite-plus/test";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import { HostProcessPlatform } from "@infinitus/shared/hostProcess";
import { ThreadId } from "@infinitus/contracts";
import { ProcessRunner } from "../../processRunner.ts";
import { resumeTarget, type LimitStop } from "../Layers/infinitusResumeOnLimit.logic.ts";
import { InfinitusSwapdProbe, InfinitusSwapdProbeLive } from "./InfinitusSwapdProbe.ts";

const account = {
  slot: 2,
  email: "two@example.com",
  active: true,
  disabled: false,
  usageStatus: "ok",
  fetchedAt: "2026-09-17T12:01:00Z",
  windows: [
    { kind: "5h", pct: 20 },
    { kind: "scoped", name: "Opus", pct: 100 },
  ],
};
const stop: LimitStop = {
  threadId: ThreadId.make("one"),
  turnId: null,
  kind: "failed",
  stoppedAt: Date.parse("2026-09-17T12:00:00Z"),
  activeAtStop: new Map([["swapd/claude", "one@example.com"]]),
  resetsAt: null,
  limitType: "five_hour",
  proxy: null,
};
const wire = (accounts: unknown = [account], provider = {}) => ({
  schemaVersion: 1,
  providers: [{ provider: "claude", activeSlot: 2, accounts, ...provider }],
});
const read = (value: unknown, platform: NodeJS.Platform = "darwin", code = 0) => {
  const calls: string[][] = [];
  return Effect.gen(function* () {
    const service = yield* InfinitusSwapdProbe;
    return { snapshot: yield* service.snapshot, calls };
  }).pipe(
    Effect.provide(
      InfinitusSwapdProbeLive.pipe(
        Layer.provide(
          Layer.succeed(ProcessRunner, {
            run: (input) => {
              calls.push([...input.args]);
              return Effect.succeed({
                stdout: typeof value === "string" ? value : JSON.stringify(value),
                stderr: "",
                code: code as never,
                timedOut: false,
                stdoutTruncated: false,
                stderrTruncated: false,
                stdoutInvalidUtf8: false,
                stderrInvalidUtf8: false,
              });
            },
          }),
        ),
      ),
    ),
    Effect.provideService(HostProcessPlatform, platform),
  );
};
it.effect("maps the daemon's current credentials and quota windows for resume", () =>
  Effect.gen(function* () {
    const { snapshot, calls } = yield* read(wire());
    expect(calls).toEqual([["--json", "--provider", "claude", "list"]]);
    expect(resumeTarget(stop, snapshot, stop.stoppedAt)).toEqual({
      fleetKey: "swapd/claude",
      from: "one@example.com",
      account: "two@example.com",
    });
    expect(
      resumeTarget({ ...stop, limitType: "seven_day_opus" }, snapshot, stop.stoppedAt),
    ).toBeNull();
  }),
);
it.effect("does not resume on stale, undated, held or unreadable credentials", () =>
  Effect.gen(function* () {
    for (const value of [
      wire([{ ...account, fetchedAt: "2026-09-17T11:59:00Z" }]),
      wire([{ ...account, fetchedAt: undefined }]),
      wire([{ ...account, fetchedAt: "bad-date" }]),
      wire([{ ...account, disabled: true }]),
      wire([account], {
        activeSlot: undefined,
        lastKnownActiveSlot: 2,
        activeUnreadable: "keychain-unavailable",
      }),
    ]) {
      const { snapshot } = yield* read(value);
      expect(resumeTarget(stop, snapshot, stop.stoppedAt)).toBeNull();
    }
  }),
);
it.effect("fails closed on malformed replies, unsupported versions, and failed commands", () =>
  Effect.gen(function* () {
    for (const value of [
      "bad-json",
      { ...wire(), schemaVersion: 2 },
      wire([{ ...account, windows: null }]),
    ]) {
      expect((yield* read(value)).snapshot.available).toBe(false);
    }
    expect((yield* read(wire(), "darwin", 1)).snapshot.available).toBe(false);
    const unsupported = yield* read(wire(), "linux");
    expect(unsupported.snapshot.available).toBe(false);
    expect(unsupported.calls).toEqual([]);
  }),
);
