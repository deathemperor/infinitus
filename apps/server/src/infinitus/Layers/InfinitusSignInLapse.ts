import {
  CommandId,
  EventId,
  type ProviderRuntimeEvent,
  type ThreadId,
  type TurnId,
} from "@infinitus/contracts";
import * as Cause from "effect/Cause";
import * as Crypto from "effect/Crypto";
import * as DateTime from "effect/DateTime";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import * as Stream from "effect/Stream";
import { makeDrainableWorker } from "@infinitus/shared/DrainableWorker";

import { OrchestrationEngineService } from "../../orchestration/Services/OrchestrationEngine.ts";
import { ProviderService } from "../../provider/Services/ProviderService.ts";
import { forkParked } from "../../serverActivation.ts";
import { InfinitusService } from "../Services/Infinitus.ts";
import { InfinitusAlertRelay } from "../Services/InfinitusAlertRelay.ts";
import { INFINITUS_HOME_DEEP_LINK } from "./InfinitusAlertRelay.ts";
import {
  hasLoginInFlight,
  manifestHasVerb,
  SIGN_IN_DEBOUNCE_MS,
  SIGN_IN_MARKER_KIND,
  signInLapseFromEvent,
  signInMarkerSummary,
  signInVerb,
  type SignInLapse,
} from "./infinitusSignInLapse.logic.ts";

/** Debounce entries kept; far more threads than a server runs, bounded so
    the map cannot grow for the process lifetime. */
const SEEN_LIMIT = 500;

/**
 * Lapsed AWS / gcloud sign-ins for the threads this server runs (#1076),
 * the fork's counterpart to the Mac's transcript scan (retired with the
 * terminal-session features, #1041). Every tool result the Claude driver
 * relays (`item.updated` with the raw `tool_result` block) is read for the
 * CLIs' expired-credentials signatures; a hit leaves one
 * `infinitus.signin.needed` work-log row on the thread ("AWS sign-in needed
 * on <profile>") and, on an app whose manifest lists the verb, starts the
 * Mac's own `aws-login <profile>` / `gcloud-login <account>` flow — through
 * `InfinitusService.command`, whose post-write poll re-reads `aws-logins`, so
 * the started login reaches the web's Sign-ins section and the phone at once
 * rather than at the next scheduled cycle. A login the snapshot's
 * `aws-logins` already shows in flight is left alone: it is waiting on a
 * person at a browser, and starting a second one would take its place.
 * Once per thread per profile per hour: a
 * session that keeps retrying the same call is one need, while a second
 * profile that lapses in the same hour is its own. Everything runs
 * on one sequential worker off the event stream, so the turn is never
 * waited on; an unreachable Mac or a refused verb is logged and the row
 * stays. The result text and the command reach no log, span or payload —
 * only the thread id, the provider and the profile.
 */
export const InfinitusSignInLapseLive = Layer.effectDiscard(
  Effect.gen(function* () {
    const providerService = yield* ProviderService;
    const orchestrationEngine = yield* OrchestrationEngineService;
    const infinitus = yield* InfinitusService;
    const alerts = yield* InfinitusAlertRelay;
    const crypto = yield* Crypto.Crypto;
    const commandId = crypto.randomUUIDv4.pipe(Effect.map(CommandId.make));
    const eventId = crypto.randomUUIDv4.pipe(Effect.map(EventId.make));
    /** `<threadId>\n<provider>\n<profile>` → when the last row was left,
        epoch ms. Keyed by profile, not by provider: one thread reaching two
        expired AWS profiles needs both logins, and a debounce over the
        provider would report only the first. */
    const seen = new Map<string, number>();

    // The snapshot answers the last poll and nobody polls a headless server:
    // an unpolled placeholder, or an app last seen down, is polled again so
    // the manifest gate can open and the `aws-logins` list below is current.
    const polled = Effect.gen(function* () {
      const snapshot = yield* infinitus.snapshot;
      if (snapshot.available) return snapshot;
      yield* infinitus.refresh;
      return yield* infinitus.snapshot;
    });

    const mark = (threadId: ThreadId, turnId: TurnId | null, lapse: SignInLapse) =>
      Effect.gen(function* () {
        const createdAt = DateTime.formatIso(yield* DateTime.now);
        yield* orchestrationEngine.dispatch({
          type: "thread.activity.append",
          commandId: yield* commandId,
          threadId,
          activity: {
            id: yield* eventId,
            tone: "info",
            kind: SIGN_IN_MARKER_KIND,
            summary: signInMarkerSummary(lapse),
            payload: { provider: lapse.provider, profile: lapse.profile, turnId },
            turnId,
            createdAt,
          },
          createdAt,
        });
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
          Effect.asVoid,
          Effect.tap(() => Effect.logInfo("infinitus.signin-lapse.login-started", context)),
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
        the Mac could start the login. An unlinked server or a refused relay is logged, never
        retried; the row and the login above stand on their own. */
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

    const onEvent = (event: ProviderRuntimeEvent) =>
      Effect.gen(function* () {
        const lapse = signInLapseFromEvent(event);
        if (lapse === null) return;
        const threadId = event.threadId;
        const key = `${threadId}\n${lapse.provider}\n${lapse.profile}`;
        const now = DateTime.toEpochMillis(yield* DateTime.now);
        const last = seen.get(key);
        if (last !== undefined && now - last < SIGN_IN_DEBOUNCE_MS) return;
        seen.delete(key);
        if (seen.size >= SEEN_LIMIT) {
          const oldest = seen.keys().next().value;
          if (oldest !== undefined) seen.delete(oldest);
        }
        seen.set(key, now);
        yield* mark(threadId, event.turnId ?? null, lapse);
        yield* login(threadId, lapse);
        yield* notify(threadId, lapse);
      });

    const worker = yield* makeDrainableWorker((event: ProviderRuntimeEvent) =>
      onEvent(event).pipe(
        // One bad event must not end the worker for every later one.
        Effect.catchCause((cause) =>
          Effect.logWarning("infinitus.signin-lapse.event-failed", {
            threadId: event.threadId,
            cause: Cause.pretty(cause),
          }),
        ),
      ),
    );

    yield* forkParked(
      providerService.streamEvents.pipe(
        // Only the relayed tool results; the content stream stays out.
        Stream.filter((event) => event.type === "item.updated"),
        Stream.runForEach((event) => worker.enqueue(event)),
      ),
    );
  }),
);
