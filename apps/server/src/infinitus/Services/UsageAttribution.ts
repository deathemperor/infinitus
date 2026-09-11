import * as Context from "effect/Context";
import type * as Effect from "effect/Effect";

/**
 * "Which Claude account was active when" for the usage scan (#779). `null`
 * when nothing can say: no Infinitus, an app without the `history` verb, an
 * engine without a swap log. `UsageService` asks once per scan and attributes
 * every Claude record through `accountAt`.
 */
export interface UsageAttributionTimeline {
  /** The account's email at the instant, `null` when unknown. */
  readonly accountAt: (timestampMs: number) => string | null;
  /** How the app names the account, and its slot while it is still in the fleet. */
  readonly describe: (email: string) => { readonly label: string; readonly number?: number };
  /** Instants of every logged switch, oldest first. */
  readonly switchesAtMs: ReadonlyArray<number>;
  /** Where the timeline came from, shown as the table's footer. */
  readonly basis: string;
}

export interface UsageAttributionShape {
  readonly resolve: Effect.Effect<UsageAttributionTimeline | null>;
}

export class UsageAttribution extends Context.Service<UsageAttribution, UsageAttributionShape>()(
  "t3/infinitus/Services/UsageAttribution",
) {}
