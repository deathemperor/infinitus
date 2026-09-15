import { Atom } from "effect/unstable/reactivity";

import { appAtomRegistry } from "../../state/atom-registry";
import type { LiveActivityTokenKind } from "./liveActivity.logic";
import {
  type AgentActivityPushState,
  type BackgroundCardNote,
  EMPTY_AGENT_ACTIVITY_PUSH_STATE,
  type PushRegistrationOutcome,
  type SwitchOffNote,
  withBackgroundCard,
  withRegistration,
  withSwitchOff,
  withWatching,
} from "./pushDiagnostics.logic";

/**
 * What this phone's push registrations have done, for the row in Settings ›
 * Infinitus (#941 step 3). Lives only in memory: it describes this run of the
 * app, and a stale line from a previous launch would be worse than none.
 */
export const agentActivityPushAtom = Atom.make(EMPTY_AGENT_ACTIVITY_PUSH_STATE).pipe(
  Atom.keepAlive,
);

const update = (next: (state: AgentActivityPushState) => AgentActivityPushState): void => {
  appAtomRegistry.set(agentActivityPushAtom, next(appAtomRegistry.get(agentActivityPushAtom)));
};

/** The thread-card bridge attached its listeners, or let them go. */
export function noteAgentActivityWatching(since: Date | null): void {
  update((state) => withWatching(state, since));
}

/** The Mac took a token. */
export function noteTokenRegistered(kind: LiveActivityTokenKind, at: Date): void {
  update((state) =>
    withRegistration(state, kind, { outcome: "registered", at: at.toISOString(), detail: null }),
  );
}

/** A send that did not land, in its own words: the Mac refused it, or the
    phone could not reach the Mac to make it (#941). */
export function noteTokenFailed(
  kind: LiveActivityTokenKind,
  at: Date,
  outcome: Exclude<PushRegistrationOutcome, "registered">,
  detail: string | null,
): void {
  update((state) => withRegistration(state, kind, { outcome, at: at.toISOString(), detail }));
}

/** No card is live any more and the Mac took the card token back (#1265). */
export function noteTokenWithdrawn(at: Date): void {
  update((state) =>
    withRegistration(state, "agent-activity", {
      outcome: "withdrawn",
      at: at.toISOString(),
      detail: null,
    }),
  );
}

/** The switch went off and the withdrawal it sent ended this way (#1265). */
export function noteSwitchOff(
  outcome: { readonly outcome: SwitchOffNote["outcome"]; readonly detail: string | null },
  at: Date,
): void {
  update((state) =>
    withSwitchOff(state, {
      outcome: outcome.outcome,
      at: at.toISOString(),
      detail: outcome.detail,
    }),
  );
}

/** A card iOS started while the app was in the background, and what its
    token did inside that window (#1277). */
export function noteBackgroundCard(note: BackgroundCardNote): void {
  update((state) => withBackgroundCard(state, note));
}
