import type { InfinitusWorkingActivityState } from "@t3tools/contracts/infinitus";

/** The card a test start shows: a fabricated fleet, every field the layout
    reads populated, so a blank or red-boxed card points at the widget and
    not at the data (#845). */
export const TEST_CARD_STATE: InfinitusWorkingActivityState = {
  active: "Test account",
  icon: null,
  slot: "#1",
  plan: "Max",
  cash: "$1.20",
  windows: [
    { label: "5h", color: "sky", pct: 42, reset: "2h10m·17:49" },
    { label: "7d", color: "amber", pct: 71, reset: "3d·Mon" },
  ],
  binding: 1,
  busy: 2,
  total: 3,
  waiting: 0,
  next: null,
  tokensPerMinute: 840,
  tokenFraction: 0.3,
  accent: "sky",
  plain: false,
  rateIcon: null,
  rateLabel: "tok/min",
};

/** A test card goes stale this long after it starts; iOS dims it then. */
export const TEST_CARD_STALE_MS = 2 * 60_000;

/** The slice of expo-widgets' `LiveActivityFactory` the row uses. */
export interface TestCardFactory {
  start(props: InfinitusWorkingActivityState, url?: string, staleDate?: Date): unknown;
  getInstances(): ReadonlyArray<{ end(dismissalPolicy?: "immediate"): Promise<void> }>;
}

export type TestCardOutcome =
  | { readonly action: "started" }
  | { readonly action: "ended"; readonly count: number }
  | { readonly action: "failed"; readonly message: string };

/** The row's label for how many working cards are live right now. */
export function testCardLabel(liveCount: number): string {
  if (liveCount === 0) return "Show a test card";
  return liveCount === 1 ? "End the working card" : `End ${liveCount} working cards`;
}

/** One press: ends every live working card when there is one (the Mac
    cannot end a card it never got an update token for), else starts the
    test card. A throw from ActivityKit — activities disabled in Settings,
    too many live, the extension missing — comes back as `failed` with
    its message, which is the diagnosis. */
export async function toggleTestCard(
  factory: TestCardFactory,
  now: Date = new Date(),
): Promise<TestCardOutcome> {
  try {
    const live = factory.getInstances();
    if (live.length > 0) {
      await Promise.all(live.map((activity) => activity.end("immediate")));
      return { action: "ended", count: live.length };
    }
    factory.start(TEST_CARD_STATE, undefined, new Date(now.getTime() + TEST_CARD_STALE_MS));
    return { action: "started" };
  } catch (error) {
    return { action: "failed", message: error instanceof Error ? error.message : String(error) };
  }
}
