import type { LiveActivityTokenKind } from "./liveActivity.logic";

/**
 * What the phone knows about its own push registrations (#941 step 3). The
 * lock-screen card's start token is handed to the app by iOS through an
 * event that simply never fires when ActivityKit declines to vend one, and
 * the failure of a send it does make is a `console.warn` a Release build
 * shows nobody — so "no card appeared" covers four different faults with one
 * silence. This is the state that tells them apart.
 */

/** What became of one attempt. `unreachable` is not a refusal: the Mac never
    saw the token, because the phone could not reach it (#941). `withdrawn`
    is the card token taken back once no card was live (#1265). */
export type PushRegistrationOutcome = "registered" | "refused" | "unreachable" | "withdrawn";

export interface PushRegistrationNote {
  readonly outcome: PushRegistrationOutcome;
  /** ISO instant of the attempt. */
  readonly at: string;
  /** The failure's own words; null for a registration, or a failure with none. */
  readonly detail: string | null;
}

export type PushRegistrations = Readonly<
  Partial<Record<LiveActivityTokenKind, PushRegistrationNote>>
>;

/** What the switch going off did to the Mac's registrations (#1265). */
export interface SwitchOffNote {
  readonly outcome: "withdrawn" | "refused" | "unreachable";
  readonly at: string;
  readonly detail: string | null;
}

export interface AgentActivityPushState {
  /** When the thread-card bridge attached its listeners; null while it is not
      running at all (the switch is off, or no paired Mac runs Infinitus). */
  readonly watchingSince: string | null;
  readonly registrations: PushRegistrations;
  /** The last switch-off's withdrawal; cleared when the bridge runs again. */
  readonly switchOff: SwitchOffNote | null;
}

export const EMPTY_AGENT_ACTIVITY_PUSH_STATE: AgentActivityPushState = {
  watchingSince: null,
  registrations: {},
  switchOff: null,
};

export function withWatching(
  state: AgentActivityPushState,
  since: Date | null,
): AgentActivityPushState {
  return since === null
    ? { ...state, watchingSince: null }
    : { ...state, watchingSince: since.toISOString(), switchOff: null };
}

export function withSwitchOff(
  state: AgentActivityPushState,
  note: SwitchOffNote,
): AgentActivityPushState {
  return { ...state, switchOff: note };
}

export function withRegistration(
  state: AgentActivityPushState,
  kind: LiveActivityTokenKind,
  note: PushRegistrationNote,
): AgentActivityPushState {
  return { ...state, registrations: { ...state.registrations, [kind]: note } };
}

const KIND_LABELS: Record<LiveActivityTokenKind, string> = {
  "agent-activity-start": "start token",
  "agent-activity": "card token",
  alert: "alert token",
};

const timeOf = (at: string) => {
  const ms = Date.parse(at);
  return Number.isFinite(ms)
    ? new Date(ms).toLocaleTimeString([], { hour: "numeric", minute: "2-digit" })
    : "an unknown time";
};

export interface AgentActivityPushSummary {
  /** The row's value, a couple of words. */
  readonly value: string;
  /** What that means and what to check, shown when the row is tapped. */
  readonly explanation: string;
}

/**
 * The one line the Settings row shows, and the paragraph behind it. The order
 * is the pipeline's own: the bridge has to be running before iOS can hand it
 * a token, and the Mac cannot refuse a token that was never sent.
 */
export function agentActivityPushSummary(state: AgentActivityPushState): AgentActivityPushSummary {
  if (state.watchingSince === null) {
    if (state.switchOff !== null) return switchOffSummary(state.switchOff);
    return {
      value: "Not running",
      explanation:
        "This phone is not offering the Mac any tokens for the lock-screen card, so nothing can start one. Turn on “Thread card on the lock screen” above, and check that a paired Mac is running Infinitus.",
    };
  }
  const start = state.registrations["agent-activity-start"];
  const card = state.registrations["agent-activity"];
  const failed = [
    { kind: "agent-activity-start" as LiveActivityTokenKind, note: start },
    { kind: "agent-activity" as LiveActivityTokenKind, note: card },
  ]
    .flatMap((entry) =>
      entry.note !== undefined &&
      entry.note.outcome !== "registered" &&
      entry.note.outcome !== "withdrawn"
        ? [{ kind: entry.kind, note: entry.note }]
        : [],
    )
    .sort((left, right) => right.note.at.localeCompare(left.note.at))[0];
  if (failed !== undefined) {
    const label = KIND_LABELS[failed.kind];
    const at = timeOf(failed.note.at);
    if (failed.note.outcome === "unreachable") {
      return {
        value: "Mac unreachable",
        explanation: `This phone could not reach the Mac to file its ${label} at ${at}: ${
          failed.note.detail ?? "it is not connected"
        }. The Mac never saw the token, so it refused nothing — the phone sends it again as soon as the Mac is reachable.`,
      };
    }
    return {
      value: "Refused",
      explanation: `The Mac refused this phone's ${label} at ${at}: ${
        failed.note.detail ?? "it gave no reason"
      }.`,
    };
  }
  if (start?.outcome === "registered") {
    const cardLine =
      card?.outcome === "registered"
        ? ` The card token followed at ${timeOf(card.at)}, so a card is live.`
        : card?.outcome === "withdrawn"
          ? ` The last card ended and its token was withdrawn at ${timeOf(
              card.at,
            )}, so the Mac starts the next card from the start token.`
          : " No card is live yet, which is normal until the Mac starts one.";
    return {
      value: "Registered",
      explanation: `The Mac has this phone's start token, filed at ${timeOf(start.at)}.${cardLine}`,
    };
  }
  if (card?.outcome === "registered") {
    return {
      value: "Card token only",
      explanation: `The Mac has the token of a card that is already running, filed at ${timeOf(
        card.at,
      )}, but not the start token it would need to raise one by itself. iOS hands that one over separately, and has not.`,
    };
  }
  return {
    value: "No token yet",
    explanation: `Watching since ${timeOf(
      state.watchingSince,
    )}. iOS has not handed this app a start token for the lock-screen card, so the Mac has nothing to raise one with. That token needs Live Activities turned on for Infinitus in the phone's own Settings, on iOS 17.2 or newer.`,
  };
}

/** The row while the switch is off: what became of the withdrawal it sent. */
function switchOffSummary(note: SwitchOffNote): AgentActivityPushSummary {
  const at = timeOf(note.at);
  switch (note.outcome) {
    case "withdrawn":
      return {
        value: "Off, withdrawn",
        explanation: `The switch is off and the Mac dropped this phone's card tokens at ${at}, so it will not push into a card that is gone. Turning the switch on registers them again.`,
      };
    case "unreachable":
      return {
        value: "Off, Mac unreachable",
        explanation: `The switch is off, but this phone could not reach the Mac to withdraw its card tokens at ${at}: ${
          note.detail ?? "it is not connected"
        }. The Mac still holds them; the phone tries again the next time the app comes to the foreground.`,
      };
    case "refused":
      return {
        value: "Off, refused",
        explanation: `The switch is off, but the Mac refused to drop this phone's card tokens at ${at}: ${
          note.detail ?? "it gave no reason"
        }.`,
      };
  }
}
