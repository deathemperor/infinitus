import type {
  InfinitusAlertInput,
  InfinitusAlertResult,
} from "@infinitus/contracts/infinitusAlert";
import { InfinitusAlertRelayUnlinked } from "@infinitus/contracts/infinitusAlert";
import * as Context from "effect/Context";
import type * as Effect from "effect/Effect";
import * as Schema from "effect/Schema";

/** The relay refused or never answered; the alert is lost. `stage` says
    where, the cause is logged, never returned on the wire. */
export class InfinitusAlertRelayFailed extends Schema.TaggedError<InfinitusAlertRelayFailed>()(
  "InfinitusAlertRelayFailed",
  {
    stage: Schema.Literals(["key_pair", "sign", "publish"]),
    cause: Schema.Defect(),
  },
) {}

export interface InfinitusAlertRelayShape {
  /** Signs the alert for the relay's `infinitusAlert` route and posts it;
      the deep link is always the phone's accounts screen. */
  readonly publish: (
    input: InfinitusAlertInput,
  ) => Effect.Effect<InfinitusAlertResult, InfinitusAlertRelayUnlinked | InfinitusAlertRelayFailed>;
}

export class InfinitusAlertRelay extends Context.Service<
  InfinitusAlertRelay,
  InfinitusAlertRelayShape
>()("t3/infinitus/Services/InfinitusAlertRelay") {}

export { InfinitusAlertRelayUnlinked };
