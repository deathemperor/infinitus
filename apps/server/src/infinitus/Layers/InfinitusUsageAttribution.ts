import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";

import { InfinitusService } from "../Services/Infinitus.ts";
import { InfinitusControlClient } from "../Services/InfinitusControlClient.ts";
import { UsageAttribution, type UsageAttributionTimeline } from "../Services/UsageAttribution.ts";
import { isNotPolled } from "./Infinitus.ts";
import {
  accountAtFactory,
  describeAccount,
  readSwitches,
} from "./infinitusUsageAttribution.logic.ts";

const HISTORY_COMMAND = "history";
const HISTORY_CAPABILITY = "history";
const BASIS = "swapd history";

const isRecord = (value: unknown): value is Record<string, unknown> =>
  typeof value === "object" && value !== null;

/**
 * The usage scan's swap timeline (#779), read from the app's `history <fleet>`
 * verb: `{fleet, history: <the engine's own switch log, whole, unstripped>}`,
 * emails included, they are the join key. Asked of the Claude fleet whose
 * engine has the `history` capability, since the app refuses the others.
 * Reads the socket through the client directly, like the secret layer,
 * because `InfinitusService.command` runs a poll cycle after every verb and a
 * usage scan must not poll the app. Anything short of a reply — no app, an
 * older build without the verb, a refused or malformed answer — is "no
 * timeline", never a failed scan. Nothing here logs the reply.
 */
export const InfinitusUsageAttributionLive = Layer.effect(
  UsageAttribution,
  Effect.gen(function* () {
    const infinitus = yield* InfinitusService;
    const client = yield* InfinitusControlClient;

    const resolve: Effect.Effect<UsageAttributionTimeline | null> = Effect.gen(function* () {
      // On a server nobody watches, `snapshot` is the pre-poll placeholder
      // until something polls; one refresh reads the manifest for real.
      let snapshot = yield* infinitus.snapshot;
      if (isNotPolled(snapshot)) {
        yield* infinitus.refresh;
        snapshot = yield* infinitus.snapshot;
      }
      if (
        !snapshot.available ||
        !snapshot.commands.some((command) => command.name === HISTORY_COMMAND)
      ) {
        return null;
      }
      const claudeFleets = snapshot.fleets.filter((fleet) => fleet.provider === "claude");
      const fleet = claudeFleets.find((candidate) =>
        candidate.capabilities.includes(HISTORY_CAPABILITY),
      );
      if (fleet === undefined) return null;
      const reply = yield* client
        .request({ command: HISTORY_COMMAND, args: [fleet.key], options: {} })
        .pipe(Effect.option);
      if (reply._tag === "None") return null;
      const switches = readSwitches(isRecord(reply.value) ? reply.value.history : undefined);
      const accounts = claudeFleets.flatMap((candidate) => candidate.accounts);
      return {
        accountAt: accountAtFactory(switches),
        describe: (email: string) => describeAccount(accounts, email),
        switchesAtMs: switches.map((row) => row.atMs),
        basis: BASIS,
      };
    }).pipe(Effect.withSpan("InfinitusUsageAttribution.resolve"));

    return UsageAttribution.of({ resolve });
  }),
);
