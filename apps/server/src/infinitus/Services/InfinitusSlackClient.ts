import * as Context from "effect/Context";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import * as Schema from "effect/Schema";
import * as Stream from "effect/Stream";

/**
 * Slack bridge (#574): the transport seam. The reactor (`Layers/InfinitusSlack.ts`)
 * reads inbound events and posts replies through this service only; the
 * Socket Mode client that fills it is its own PR. Text arrives plain
 * (the transport unwraps Slack's escaping and `<url|label>` links).
 */

export type SlackInbound =
  | {
      readonly kind: "mention";
      readonly envelopeId: string;
      readonly channel: string;
      /** The message's own ts: the thread every reply to this task lands in. */
      readonly threadTs: string;
      readonly userId: string;
      readonly text: string;
    }
  | {
      readonly kind: "reply";
      readonly envelopeId: string;
      readonly channel: string;
      readonly threadTs: string;
      readonly userId: string;
      readonly text: string;
    }
  | {
      readonly kind: "action";
      readonly envelopeId: string;
      readonly channel: string;
      readonly threadTs: string;
      readonly userId: string;
      readonly actionId: string;
      readonly value: string;
    };

export interface SlackPost {
  readonly channel: string;
  readonly threadTs?: string;
  readonly text: string;
  /** Block Kit blocks; the transport passes them through untouched. */
  readonly blocks?: ReadonlyArray<unknown>;
}

export class SlackPostError extends Schema.TaggedError<SlackPostError>()("SlackPostError", {
  reason: Schema.String,
}) {}

export interface SlackClientShape {
  readonly inbound: Stream.Stream<SlackInbound>;
  readonly post: (post: SlackPost) => Effect.Effect<{ readonly ts: string }, SlackPostError>;
}

export class SlackClient extends Context.Service<SlackClient, SlackClientShape>()(
  "t3/infinitus/Services/InfinitusSlackClient/SlackClient",
) {}

/** No transport yet: nothing arrives, and a post says so. */
export const SlackClientInert = Layer.succeed(SlackClient)({
  inbound: Stream.never,
  post: () => Effect.fail(new SlackPostError({ reason: "no Slack transport" })),
});
