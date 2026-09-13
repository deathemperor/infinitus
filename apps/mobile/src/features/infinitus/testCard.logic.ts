import type { AgentActivityProps } from "../../widgets/AgentActivity";

/** The card a test start shows: a fabricated environment with a thread in
    every phase the layout ranks, so a blank or red-boxed card points at
    the widget and not at the data (#845, #1047). */
export const TEST_CARD_STATE: AgentActivityProps = {
  title: "2 threads working",
  subtitle: "Test environment",
  activeCount: 2,
  updatedAt: "2026-09-13T10:00:00.000Z",
  activities: [
    {
      environmentId: "test-env",
      threadId: "test-approval",
      projectTitle: "limitless",
      threadTitle: "Nightly track",
      modelTitle: "Fable",
      phase: "waiting_for_approval",
      status: "Approval",
      updatedAt: "2026-09-13T09:58:00.000Z",
      deepLink: "/",
    },
    {
      environmentId: "test-env",
      threadId: "test-running",
      projectTitle: "limitless",
      threadTitle: "PATH fallback",
      modelTitle: "Opus",
      phase: "running",
      status: "Working",
      updatedAt: "2026-09-13T10:00:00.000Z",
      deepLink: "/",
    },
    {
      environmentId: "test-env",
      threadId: "test-done",
      projectTitle: "limitless",
      threadTitle: "Stale rows",
      modelTitle: "Sonnet",
      phase: "completed",
      status: "Done",
      updatedAt: "2026-09-13T09:40:00.000Z",
      deepLink: "/",
    },
  ],
};

/** A test card goes stale this long after it starts; iOS dims it then. */
export const TEST_CARD_STALE_MS = 2 * 60_000;

/** How long the test card's working row claims to have been running, so its
    elapsed timer starts at a plausible figure and ticks up from there (#1047). */
const TEST_CARD_ELAPSED_MS = 90_000;

/** The test card as it is shown: the base rows with the working one's
    `startedAt` set against the moment of the press, since a fixed instant
    would have the row's timer read in days. */
export function testCardState(now: Date): AgentActivityProps {
  const startedAt = new Date(now.getTime() - TEST_CARD_ELAPSED_MS).toISOString();
  return {
    ...TEST_CARD_STATE,
    activities: TEST_CARD_STATE.activities.map((row) =>
      row.phase === "running" ? { ...row, startedAt } : row,
    ),
  };
}

/** The slice of expo-widgets' `LiveActivityFactory` the row uses. */
export interface TestCardFactory {
  start(props: AgentActivityProps, url?: string, staleDate?: Date): unknown;
  getInstances(): ReadonlyArray<{ end(dismissalPolicy?: "immediate"): Promise<void> }>;
}

export type TestCardOutcome =
  | { readonly action: "started" }
  | { readonly action: "ended"; readonly count: number }
  | { readonly action: "failed"; readonly message: string };

/** The row's label for how many thread cards are live right now. */
export function testCardLabel(liveCount: number): string {
  if (liveCount === 0) return "Show a test card";
  return liveCount === 1 ? "End the thread card" : `End ${liveCount} thread cards`;
}

/** One press: ends every live card when there is one (the Mac cannot end a
    card it never got a token for), else starts the test card. A throw from
    ActivityKit — activities disabled in Settings, too many live, the
    extension missing — comes back as `failed` with its message, which is
    the diagnosis. */
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
    factory.start(testCardState(now), undefined, new Date(now.getTime() + TEST_CARD_STALE_MS));
    return { action: "started" };
  } catch (error) {
    return { action: "failed", message: error instanceof Error ? error.message : String(error) };
  }
}
