import type { ThreadId } from "@t3tools/contracts";
import { create } from "zustand";

/**
 * Fork (#269 C follow-up): the question a failed side thread's Retry re-asks
 * on the fresh fork. ChatView offers it under the new side thread's id the
 * moment the fork answers; the drawer takes it once, when that thread is
 * ready, and sends it. In memory only.
 */
interface PendingSideQuestionState {
  byThread: Readonly<Record<string, string>>;
  offer: (threadId: ThreadId, question: string) => void;
  take: (threadId: ThreadId) => string | null;
}

export const usePendingSideQuestionStore = create<PendingSideQuestionState>()((set, get) => ({
  byThread: {},
  offer: (threadId, question) =>
    set((state) => ({ byThread: { ...state.byThread, [threadId]: question } })),
  take: (threadId) => {
    const question = get().byThread[threadId] ?? null;
    if (question !== null) {
      set((state) => {
        const { [threadId]: _taken, ...rest } = state.byThread;
        return { byThread: rest };
      });
    }
    return question;
  },
}));
