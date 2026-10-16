import type { ThreadId } from "@infinitus/contracts";
import * as Context from "effect/Context";
import type * as Effect from "effect/Effect";

export interface EventNdjsonLogger {
  readonly filePath: string;
  readonly write: (event: unknown, threadId: ThreadId | null) => Effect.Effect<void>;
  readonly close: () => Effect.Effect<void>;
}

export class ProviderEventLoggers extends Context.Service<
  ProviderEventLoggers,
  {
    readonly native: EventNdjsonLogger | undefined;
    readonly canonical: EventNdjsonLogger | undefined;
  }
>()("@infinitus/provider-core/server/ProviderEventLoggers") {}

export const NoOpProviderEventLoggers: ProviderEventLoggers["Service"] = {
  native: undefined,
  canonical: undefined,
};
