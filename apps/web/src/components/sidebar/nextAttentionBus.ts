// The command palette's "Jump to next waiting thread" action and the
// `thread.nextAttention` key share one resolver, which lives in the sidebar
// because only it holds the rendered order, statuses and holds (#270 C). The
// palette asks over a window event the way commandPaletteBus opens the
// palette, so neither component owns the other's state.
const NEXT_ATTENTION_THREAD_EVENT = "t3code:next-attention-thread";

export function requestNextAttentionThread(): void {
  window.dispatchEvent(new CustomEvent(NEXT_ATTENTION_THREAD_EVENT));
}

export function onNextAttentionThreadRequest(listener: () => void): () => void {
  window.addEventListener(NEXT_ATTENTION_THREAD_EVENT, listener);
  return () => window.removeEventListener(NEXT_ATTENTION_THREAD_EVENT, listener);
}
