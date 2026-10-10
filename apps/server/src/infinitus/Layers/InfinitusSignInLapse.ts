import type { OrchestrationV2TurnItem, ThreadId } from "@infinitus/contracts";
import * as Cause from "effect/Cause";
import * as DateTime from "effect/DateTime";
import * as Duration from "effect/Duration";
import * as Effect from "effect/Effect";
import * as FiberMap from "effect/FiberMap";
import * as Layer from "effect/Layer";
import * as Stream from "effect/Stream";
import { makeDrainableWorker } from "@infinitus/shared/DrainableWorker";

import * as Orchestrator from "../../orchestration-v2/Orchestrator.ts";
import { ProcessRunner } from "../../processRunner.ts";
import { forkParked } from "../../serverActivation.ts";
import { InfinitusService } from "../Services/Infinitus.ts";
import { InfinitusAlertRelay } from "../Services/InfinitusAlertRelay.ts";
import { InfinitusControlClient } from "../Services/InfinitusControlClient.ts";
import { INFINITUS_HOME_DEEP_LINK } from "./InfinitusAlertRelay.ts";
import {
  agentLoginPids,
  hasLoginInFlight,
  macLoginState,
  manifestHasVerb,
  SIGN_IN_DEBOUNCE_MS,
  signInFromTurnItem,
  signInVerb,
  type SignInLapse,
} from "./infinitusSignInLapse.logic.ts";

/** Debounce entries kept; far more threads than a server runs, bounded so
    the map cannot grow for the process lifetime. */
const SEEN_LIMIT = 500;

/** How often a login the agent runs itself re-reads the Mac's login for the
    same credential; the Mac ends its own after ten minutes. */
const WATCH_INTERVAL = Duration.seconds(3);

/**
 * Lapsed AWS / gcloud sign-ins for the threads this server runs (#1076),
 * the fork's counterpart to the Mac's transcript scan (retired with the
 * terminal-session features, #1041), on orchestrator v2 (#1627). Every
 * `command_execution` turn item the orchestrator stores — the adapters
 * normalize every provider's shell tool into one, so this is no longer
 * Claude's alone — is read for the CLIs' expired-credentials signatures once
 * it carries its output, and as it starts (running, no output yet) for a
 * login the agent runs itself (`aws login`, `gcloud auth login`: it blocks
 * on a browser no client shows). A hit, on an app whose manifest lists the
 * verb, starts the Mac's own `aws-login <profile>` / `gcloud-login <account>`
 * flow — through `InfinitusService.command`, whose post-write poll re-reads
 * `aws-logins`, so the started login reaches the web's Sign-ins section and
 * the phone at once rather than at the next scheduled cycle — and rings the
 * phones once through the relay. (The v1 work-log row on the thread left
 * with the port: v2 has no row a reactor can leave, and no client drew it.)
 * A login the snapshot's `aws-logins` already shows in flight is left alone:
 * it is waiting on a person at a browser, and starting a second one would
 * take its place. Once per thread per profile per hour: a session that
 * keeps retrying the same call is one need, while a second profile that
 * lapses in the same hour is its own, and so is every login the agent runs
 * itself (once per tool call). Everything runs on one sequential worker off
 * the event stream, so the turn is never waited on; an unreachable Mac or a
 * refused verb is logged. A login the agent runs itself waits on its own
 * browser tab, which signing in through the Mac's card never answers, so
 * its Bash call would sit until its timeout: the Mac's login is watched
 * until it ends, and once it is `done` the agent's login processes for that
 * credential — under this server's process tree only — are ended, and the
 * agent's next call finds the Mac's credentials. The output text and the
 * command reach no log, span or payload — only the thread id, the provider
 * and the profile.
 */
export const InfinitusSignInLapseLive = Layer.effectDiscard(
  Effect.gen(function* () {
    const orchestrator = yield* Orchestrator.OrchestratorV2;
    const infinitus = yield* InfinitusService;
    const alerts = yield* InfinitusAlertRelay;
    const control = yield* InfinitusControlClient;
    const runner = yield* ProcessRunner;
    /** `<threadId>\n<provider>\n<profile>` → when the need was last met,
        epoch ms. Keyed by profile, not by provider: one thread reaching two
        expired AWS profiles needs both logins, and a debounce over the
        provider would report only the first. */
    const seen = new Map<string, number>();
    /** `<provider>\n<profile>` → the profile the Mac runs its login under,
        from the start reply: it resolves a `credential_process` profile to
        the login profile it names, and answers `--status` only by that one. */
    const macProfiles = new Map<string, string>();
    /** One watch per Mac login, whichever thread started it. */
    const watches = yield* FiberMap.make<string>();

    // The snapshot answers the last poll and nobody polls a headless server:
    // an unpolled placeholder, or an app last seen down, is polled again so
    // the manifest gate can open and the `aws-logins` list below is current.
    const polled = Effect.gen(function* () {
      const snapshot = yield* infinitus.snapshot;
      if (snapshot.available) return snapshot;
      yield* infinitus.refresh;
      return yield* infinitus.snapshot;
    });

    const login = (threadId: ThreadId, lapse: SignInLapse) => {
      const verb = signInVerb(lapse.provider);
      const context = { threadId, provider: lapse.provider };
      return Effect.gen(function* () {
        const snapshot = yield* polled;
        if (!snapshot.available || !manifestHasVerb(snapshot.commands, verb)) {
          yield* Effect.logDebug("infinitus.signin-lapse.no-verb", context);
          return;
        }
        // A login already open is waiting on a person at a browser; a second
        // one would take its place and lose the tab they are looking at.
        if (hasLoginInFlight(snapshot.awsLogins ?? [], lapse)) {
          yield* Effect.logDebug("infinitus.signin-lapse.in-flight", context);
          return;
        }
        yield* infinitus.command({ command: verb, args: [lapse.profile], options: {} }).pipe(
          Effect.tap((reply) => {
            const state = macLoginState(reply);
            if (state !== null) {
              macProfiles.set(`${lapse.provider}\n${lapse.profile}`, state.profile);
            }
            return Effect.logInfo("infinitus.signin-lapse.login-started", context);
          }),
          Effect.asVoid,
          Effect.catchTags({
            InfinitusUnavailable: () =>
              Effect.logDebug("infinitus.signin-lapse.unavailable", context),
            InfinitusProtocolError: (error) =>
              Effect.logWarning("infinitus.signin-lapse.refused", {
                ...context,
                detail: error.detail,
              }),
            InfinitusCommandFailed: (error) =>
              Effect.logWarning("infinitus.signin-lapse.refused", {
                ...context,
                error: error.error,
              }),
          }),
        );
      });
    };

    /** The phones hear about it (user 2026-09-17): one push through the
        relay, deep-linked to the home screen's sign-in cards, whether or not
        the Mac could start the login. An unlinked server or a refused relay
        is logged, never retried; the login above stands on its own. */
    const notify = (threadId: ThreadId, lapse: SignInLapse) =>
      alerts
        .publish({
          title: `${lapse.provider === "aws" ? "AWS" : "gcloud"} sign-in needed`,
          body: `${lapse.profile} has expired credentials. Open Infinitus to sign in from this phone.`,
          deepLink: INFINITUS_HOME_DEEP_LINK,
        })
        .pipe(
          Effect.asVoid,
          Effect.catchTags({
            InfinitusAlertRelayUnlinked: () =>
              Effect.logDebug("infinitus.signin-lapse.alert-unlinked", { threadId }),
            InfinitusAlertRelayFailed: (error) =>
              Effect.logWarning("infinitus.signin-lapse.alert-failed", {
                threadId,
                stage: error.stage,
              }),
          }),
        );

    /** The Mac's login for this credential as `--status` reports it; null when
        it has none or cannot be asked. A read, so no snapshot refresh. */
    const macLogin = (lapse: SignInLapse, profile: string) =>
      control
        .request({
          command: signInVerb(lapse.provider),
          args: [profile],
          options: { status: "true" },
        })
        .pipe(
          Effect.map(macLoginState),
          Effect.orElseSucceed(() => null),
        );

    /** Ends this server's agents' logins for the credential the Mac just
        signed in: `ps` for the tree under this process, `kill -TERM` for the
        CLI processes found there. */
    const endAgentLogins = (lapse: SignInLapse, profile: string) =>
      Effect.gen(function* () {
        const ps = yield* runner.run({
          command: "ps",
          args: ["-eo", "pid=,ppid=,args="],
          timeout: "5 seconds",
        });
        const pids = agentLoginPids(
          ps.stdout,
          process.pid,
          lapse.provider,
          new Set([lapse.profile, profile]),
        );
        if (pids.length === 0) return;
        yield* runner.run({
          command: "kill",
          args: ["-TERM", ...pids.map(String)],
          timeout: "5 seconds",
        });
        yield* Effect.logInfo("infinitus.signin-lapse.agent-login-ended", {
          provider: lapse.provider,
          count: pids.length,
        });
      }).pipe(
        Effect.catchCause((cause) =>
          Effect.logWarning("infinitus.signin-lapse.agent-login-end-failed", {
            provider: lapse.provider,
            cause: Cause.pretty(cause),
          }),
        ),
      );

    /** Follows the Mac's login while it is in flight: `done` ends the
        agent's own, a failed, dismissed or unreachable one ends the watch
        and leaves the agent's login to its timeout. A login already over at
        the first read is someone else's earlier outcome, not this one's. */
    const watch = (lapse: SignInLapse) => {
      const profile = macProfiles.get(`${lapse.provider}\n${lapse.profile}`) ?? lapse.profile;
      return FiberMap.run(watches, `${lapse.provider}\n${profile}`, { onlyIfMissing: true })(
        Effect.gen(function* () {
          let state = yield* macLogin(lapse, profile);
          while (state !== null && state.phase !== "done" && state.phase !== "failed") {
            yield* Effect.sleep(WATCH_INTERVAL);
            state = yield* macLogin(lapse, profile);
            if (state?.phase === "done") yield* endAgentLogins(lapse, state.profile);
          }
        }),
      );
    };

    const onItem = (item: OrchestrationV2TurnItem) =>
      Effect.gen(function* () {
        const read = signInFromTurnItem(item);
        if (read === null) return;
        const { lapse, run } = read;
        const threadId = item.threadId;
        // A login the agent runs itself blocks on its browser tab now, however
        // recently the profile lapsed: each tool call is its own need. The
        // same item is stored again as its presentation fills in; one id.
        const key = run
          ? `${threadId}\nrun\n${item.id}`
          : `${threadId}\n${lapse.provider}\n${lapse.profile}`;
        const now = DateTime.toEpochMillis(yield* DateTime.now);
        const last = seen.get(key);
        if (last === undefined || now - last >= SIGN_IN_DEBOUNCE_MS) {
          seen.delete(key);
          if (seen.size >= SEEN_LIMIT) {
            const oldest = seen.keys().next().value;
            if (oldest !== undefined) seen.delete(oldest);
          }
          seen.set(key, now);
          yield* login(threadId, lapse);
          yield* notify(threadId, lapse);
        }
        if (run) yield* watch(lapse);
      });

    const worker = yield* makeDrainableWorker((item: OrchestrationV2TurnItem) =>
      onItem(item).pipe(
        // One bad item must not end the worker for every later one.
        Effect.catchCause((cause) =>
          Effect.logWarning("infinitus.signin-lapse.event-failed", {
            threadId: item.threadId,
            cause: Cause.pretty(cause),
          }),
        ),
      ),
    );

    yield* forkParked(
      orchestrator.streamDomainEvents.pipe(
        // The live tail only (no replay from genesis); the shell tools' items,
        // start and finish, and nothing else reaches the worker.
        Stream.runForEach((event) =>
          event.type === "turn-item.updated" && event.payload.type === "command_execution"
            ? worker.enqueue(event.payload)
            : Effect.void,
        ),
        // The tail ending is the orchestrator's to report; this layer says so
        // once and leaves the already-queued items to the worker.
        Effect.catchCause((cause) =>
          Effect.logWarning("infinitus.signin-lapse.stream-ended", {
            cause: Cause.pretty(cause),
          }),
        ),
      ),
    );
  }),
);
