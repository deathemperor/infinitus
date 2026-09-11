import { create } from "zustand";

/**
 * A team join link the desktop received (#270 D follow-up): the code rides
 * here, in memory only, from the deep link to the Team page's Join field.
 * It is a secret: never persisted, never logged, taken once, and sent only
 * when the user presses Request to join.
 */
interface PendingTeamJoinState {
  code: string | null;
  offer: (code: string) => void;
  take: () => string | null;
}

export const usePendingTeamJoinStore = create<PendingTeamJoinState>()((set, get) => ({
  code: null,
  offer: (code) => set({ code }),
  take: () => {
    const code = get().code;
    if (code !== null) set({ code: null });
    return code;
  },
}));
