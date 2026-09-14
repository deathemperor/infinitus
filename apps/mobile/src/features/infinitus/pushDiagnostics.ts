import { Atom } from "effect/unstable/reactivity";

import { appAtomRegistry } from "../../state/atom-registry";
import type { LiveActivityTokenKind } from "./liveActivity.logic";
import {
  type AgentActivityPushState,
  EMPTY_AGENT_ACTIVITY_PUSH_STATE,
  withRegistration,
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

/** The Mac refused one, in its own words. */
export function noteTokenRefused(
  kind: LiveActivityTokenKind,
  at: Date,
  detail: string | null,
): void {
  update((state) =>
    withRegistration(state, kind, { outcome: "refused", at: at.toISOString(), detail }),
  );
}
