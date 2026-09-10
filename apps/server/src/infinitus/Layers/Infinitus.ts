import {
  InfinitusCommandFailed,
  InfinitusForecast,
  InfinitusFleet,
  InfinitusManifest,
  InfinitusPrefs,
  InfinitusSession,
  InfinitusStatus,
  type InfinitusCommandInput,
  type InfinitusManifestCommand,
  type InfinitusProtocolError,
  type InfinitusSnapshot,
  type InfinitusUnavailable,
} from "@t3tools/contracts/infinitus";
import * as Clock from "effect/Clock";
import * as Duration from "effect/Duration";
import * as Effect from "effect/Effect";
import * as FiberHandle from "effect/FiberHandle";
import * as Layer from "effect/Layer";
import * as Ref from "effect/Ref";
import * as Schema from "effect/Schema";
import * as Semaphore from "effect/Semaphore";
import * as Stream from "effect/Stream";
import * as SubscriptionRef from "effect/SubscriptionRef";

import { InfinitusService, type InfinitusServiceShape } from "../Services/Infinitus.ts";
import { InfinitusControlClient } from "../Services/InfinitusControlClient.ts";

/** How often the cheap commands run while somebody is watching. */
const FAST_POLL_INTERVAL = Duration.seconds(5);
/** How often the expensive ones do — a forecast recomputes a run rate, and the
    pref catalog only changes when a person changes it. */
const SLOW_POLL_INTERVAL = Duration.seconds(30);
/** While the app is unreachable, only `status` is tried, and less often: a
    dead socket answers ENOENT immediately, so this is purely politeness. */
const UNAVAILABLE_PROBE_INTERVAL = Duration.seconds(15);

/** The command whose absence from the manifest means the running app predates
    the pref catalog. Polling it anyway would fail every slow cycle. */
const PREFS_COMMAND = "prefs";

const decodeStatus = Schema.decodeUnknownEffect(InfinitusStatus);
// `fleets` and `sessions` answer with a bare JSON array; the rest wrap.
const decodeFleets = Schema.decodeUnknownEffect(Schema.Array(InfinitusFleet));
const decodeSessions = Schema.decodeUnknownEffect(Schema.Array(InfinitusSession));
const decodeForecast = Schema.decodeUnknownEffect(InfinitusForecast);
const decodePrefs = Schema.decodeUnknownEffect(InfinitusPrefs);
const decodeManifest = Schema.decodeUnknownEffect(InfinitusManifest);

const unavailableSnapshot = (reason: string): InfinitusSnapshot => ({
  available: false,
  unavailableReason: reason,
  fleets: [],
  sessions: [],
  commands: [],
});

/**
 * One command's outcome as the poller cares about it: a value, nothing usable
 * (the reply failed or did not match the contract — that field goes absent for
 * this cycle), or an app that is not there, which ends the cycle.
 */
type Fetched<A> =
  | { readonly kind: "value"; readonly value: A }
  | { readonly kind: "absent" }
  | { readonly kind: "unavailable"; readonly reason: string };

const makeInfinitus = Effect.gen(function* () {
  const client = yield* InfinitusControlClient;

  const state = yield* SubscriptionRef.make<InfinitusSnapshot>(
    unavailableSnapshot("the socket has not been polled yet"),
  );
  /** The last manifest that decoded. Kept across unavailability so a command
      is still checked against a table while the app restarts. */
  const commands = yield* Ref.make<ReadonlyArray<InfinitusManifestCommand>>([]);
  /** Set on every fall to unavailable: the next available cycle re-reads the
      manifest, because the app that came back may not be the one that left. */
  const manifestStale = yield* Ref.make(true);
  const nextSlowAtMillis = yield* Ref.make(0);
  /** Bumped every time the app is lost. Only used to scope the decode
      warnings, so one broken build does not log on every cycle forever. */
  const generation = yield* Ref.make(0);
  const warnedCommands = yield* Ref.make<ReadonlySet<string>>(new Set());
  const subscribers = yield* Ref.make(0);
  /** Serializes the polling cycle against the refresh a write schedules, so
      the two never interleave their reads into one snapshot. */
  const pollLock = yield* Semaphore.make(1);
  /** Guards the subscriber count's edges: without it a 1 -> 0 -> 1 flip could
      stop the loop the new subscriber just started. */
  const lifecycleLock = yield* Semaphore.make(1);
  const pollHandle = yield* FiberHandle.make<void, never>();
  const refreshHandle = yield* FiberHandle.make<void, never>();

  const warnOnce = Effect.fn("Infinitus.warnOnce")(function* (command: string, error: unknown) {
    if ((yield* Ref.get(warnedCommands)).has(command)) return;
    yield* Ref.update(warnedCommands, (warned) => new Set(warned).add(command));
    yield* Effect.logWarning("infinitus.poll.unusable-reply", {
      command,
      generation: yield* Ref.get(generation),
      error,
    });
  });

  const fetchCommand = <A>(
    command: string,
    decode: (input: unknown) => Effect.Effect<A, Schema.SchemaError>,
  ): Effect.Effect<Fetched<A>> =>
    client.request({ command }).pipe(
      Effect.flatMap(decode),
      Effect.map((value): Fetched<A> => ({ kind: "value", value })),
      Effect.catchTag("InfinitusUnavailable", (error) =>
        Effect.succeed<Fetched<A>>({ kind: "unavailable", reason: error.cause }),
      ),
      // A protocol error, a refused command, an undecodable reply: the app is
      // there and answering, so the poll goes on with that one field missing.
      Effect.catch((error) =>
        warnOnce(command, error).pipe(Effect.as<Fetched<A>>({ kind: "absent" })),
      ),
    );

  const goUnavailable = Effect.fn("Infinitus.goUnavailable")(function* (reason: string) {
    yield* Ref.set(manifestStale, true);
    yield* Ref.set(nextSlowAtMillis, 0);
    // The app that comes back may be a different build, so its replies get a
    // fresh set of warnings. Doing this here rather than on the way back keeps
    // a manifest that never decodes from re-warning on every cycle.
    if ((yield* SubscriptionRef.get(state)).available) {
      yield* Ref.update(generation, (previous) => previous + 1);
      yield* Ref.set(warnedCommands, new Set<string>());
    }
    yield* SubscriptionRef.set(state, unavailableSnapshot(reason));
    return UNAVAILABLE_PROBE_INTERVAL;
  });

  /** One pass over the socket. Answers with how long to wait before the next
      one, which is the only thing that tells fast, slow and probe apart. */
  const runCycle = Effect.gen(function* () {
    const status = yield* fetchCommand("status", decodeStatus);
    if (status.kind === "unavailable") return yield* goUnavailable(status.reason);

    if (yield* Ref.get(manifestStale)) {
      const manifest = yield* fetchCommand("manifest", decodeManifest);
      if (manifest.kind === "unavailable") return yield* goUnavailable(manifest.reason);
      if (manifest.kind === "value") {
        yield* Ref.set(commands, manifest.value.commands);
        yield* Ref.set(manifestStale, false);
      }
    }

    const fleets = yield* fetchCommand("fleets", decodeFleets);
    if (fleets.kind === "unavailable") return yield* goUnavailable(fleets.reason);
    const sessions = yield* fetchCommand("sessions", decodeSessions);
    if (sessions.kind === "unavailable") return yield* goUnavailable(sessions.reason);

    const previous = yield* SubscriptionRef.get(state);
    const knownCommands = yield* Ref.get(commands);
    const now = yield* Clock.currentTimeMillis;
    const slowDue = now >= (yield* Ref.get(nextSlowAtMillis));

    // Off a slow cycle the expensive fields ride along from the last one, so a
    // fast tick never blanks a forecast the client is already showing.
    let forecast = slowDue ? undefined : previous.forecast;
    let prefs = slowDue ? undefined : previous.prefs;
    if (slowDue) {
      const fetched = yield* fetchCommand("forecast", decodeForecast);
      if (fetched.kind === "unavailable") return yield* goUnavailable(fetched.reason);
      if (fetched.kind === "value") forecast = fetched.value;

      if (knownCommands.some((entry) => entry.name === PREFS_COMMAND)) {
        const fetchedPrefs = yield* fetchCommand(PREFS_COMMAND, decodePrefs);
        if (fetchedPrefs.kind === "unavailable") return yield* goUnavailable(fetchedPrefs.reason);
        if (fetchedPrefs.kind === "value") prefs = fetchedPrefs.value;
      }
      yield* Ref.set(nextSlowAtMillis, now + Duration.toMillis(SLOW_POLL_INTERVAL));
    }

    yield* SubscriptionRef.set(state, {
      available: true,
      ...(status.kind === "value" ? { status: status.value } : {}),
      fleets: fleets.kind === "value" ? fleets.value : [],
      ...(forecast === undefined ? {} : { forecast }),
      sessions: sessions.kind === "value" ? sessions.value : [],
      ...(prefs === undefined ? {} : { prefs }),
      commands: knownCommands,
    });
    return FAST_POLL_INTERVAL;
  });

  const guardedCycle = pollLock.withPermits(1)(runCycle);

  const pollLoop = guardedCycle.pipe(
    Effect.flatMap((interval) => Effect.sleep(interval)),
    Effect.forever,
    Effect.asVoid,
  );

  const startPolling = lifecycleLock.withPermits(1)(
    Effect.gen(function* () {
      const count = yield* Ref.updateAndGet(subscribers, (previous) => previous + 1);
      if (count > 1) return;
      // `startImmediately` is what makes the first subscriber's poll immediate
      // rather than one scheduler turn away.
      yield* FiberHandle.run(pollHandle, pollLoop, { startImmediately: true });
    }),
  );

  const stopPolling = lifecycleLock.withPermits(1)(
    Effect.gen(function* () {
      const count = yield* Ref.updateAndGet(subscribers, (previous) => Math.max(0, previous - 1));
      if (count > 0) return;
      yield* FiberHandle.clear(pollHandle);
    }),
  );

  const changes = Stream.unwrap(
    Effect.gen(function* () {
      // Counting the subscriber first is what makes the loop's immediate cycle
      // land before the subscription: a `SubscriptionRef` replays one value, so
      // the current snapshot is the stream's first element either way.
      yield* Effect.acquireRelease(startPolling, () => stopPolling);
      return SubscriptionRef.changes(state).pipe(Stream.changes);
    }),
  );

  const command = Effect.fn("Infinitus.command")(function* (
    input: InfinitusCommandInput,
  ): Effect.fn.Return<
    unknown,
    InfinitusUnavailable | InfinitusProtocolError | InfinitusCommandFailed
  > {
    const knownCommands = yield* Ref.get(commands);
    // An empty table means no poll has ever read one, not that the app has no
    // commands — then the socket itself judges the name.
    if (knownCommands.length > 0 && !knownCommands.some((entry) => entry.name === input.command)) {
      return yield* new InfinitusCommandFailed({
        command: input.command,
        error: "unknown command",
        restarting: false,
      });
    }

    const result = yield* client.request({
      command: input.command,
      args: input.args,
      options: input.options,
    });

    // A write moved something the last cycle already read. Detached so the
    // caller's reply does not wait on it — a `restart` command leaves a socket
    // that answers nothing until the app is back.
    yield* FiberHandle.run(refreshHandle, guardedCycle.pipe(Effect.asVoid), {
      startImmediately: true,
    });
    return result;
  });

  return {
    snapshot: SubscriptionRef.get(state),
    changes,
    command,
  } satisfies InfinitusServiceShape;
});

export const InfinitusLive = Layer.effect(InfinitusService, makeInfinitus);
