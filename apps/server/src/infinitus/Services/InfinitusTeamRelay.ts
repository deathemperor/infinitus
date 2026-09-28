import * as Context from "effect/Context";
import type * as Effect from "effect/Effect";
import type * as Scope from "effect/Scope";

export interface InfinitusTeamRelayShape {
  /** The loops: `now` every minute, the other kinds every five, the
      command poll every fifteen seconds while a grant names this machine. */
  readonly start: () => Effect.Effect<void, never, Scope.Scope>;
  /** One `now` publish for every team this machine's user is in. */
  readonly publishNow: Effect.Effect<void>;
  /** One publish of fleet, threads, changed stats days and new transcript
      rows for every team. */
  readonly publishAll: Effect.Effect<void>;
  /** One poll: runs or refuses what the relay holds for this machine and
      acks each command. */
  readonly pollCommands: Effect.Effect<void>;
}

/** The desktop's half of Team on Infinitus Connect (#1592). Never fails:
    an unlinked server, a user in no team or an unreachable relay log and
    wait for the next cycle. */
export class InfinitusTeamRelay extends Context.Service<
  InfinitusTeamRelay,
  InfinitusTeamRelayShape
>()("t3/infinitus/Services/InfinitusTeamRelay") {}
